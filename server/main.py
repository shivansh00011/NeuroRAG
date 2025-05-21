from fastapi import FastAPI, UploadFile, File, Form, HTTPException
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import List
import uuid
import pdfplumber
import datetime
import numpy as np
from sklearn.neighbors import NearestNeighbors
from sentence_transformers import SentenceTransformer
import os
import pickle
import google.generativeai as genai
import tiktoken
import shutil

# Set environment variable for tokenizers
os.environ["TOKENIZERS_PARALLELISM"] = "false"

# Create necessary directories
os.makedirs("server/data", exist_ok=True)
os.makedirs("server/temp", exist_ok=True)

# Initialize app and model
app = FastAPI(title="NeuroRAG API")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)
@app.get("/")
async def root():
    return {"message": "Welcome to NeuroRAG API", "status": "healthy"}

# Configure Gemini
try:
    api_key = "AIzaSyA1WLutHTzxRj-pqYLdVSN4E2WgoKf__L0"
    if not api_key:
        print("Warning: GEMINI_API_KEY environment variable not set")
    genai.configure(
        api_key=api_key,
        transport='rest'
    )
except Exception as e:
    print(f"Error configuring Gemini: {e}")

# Initialize model
try:
    model = SentenceTransformer("all-MiniLM-L6-v2")
except Exception as e:
    print(f"Error loading model: {e}")
    model = None

# In-memory vector DB
EMBEDDING_SIZE = 384
neighbors = NearestNeighbors(n_neighbors=5, metric='euclidean')
chunk_store = {}  # id: {text, metadata, embedding}
embeddings_list = []  # List to store embeddings for NearestNeighbors

# Persist storage paths
STORE_PATH = "server/data/neuro_memory.pkl"
EMBEDDINGS_PATH = "server/data/embeddings.npy"
DUMP_PATH = "server/data/memory_dump.pkl"

# Load memory if exists
try:
    if os.path.exists(STORE_PATH):
        with open(STORE_PATH, "rb") as f:
            chunk_store = pickle.load(f)
    
    if os.path.exists(EMBEDDINGS_PATH):
        embeddings_list = np.load(EMBEDDINGS_PATH).tolist()  # Convert to list for appending
        if len(embeddings_list) > 0:
            neighbors.fit(np.array(embeddings_list))
except Exception as e:
    print(f"Error loading existing data: {e}")

class Query(BaseModel):
    query: str

def num_tokens_from_string(string: str, model_name: str = "cl100k_base") -> int:
    encoding = tiktoken.get_encoding(model_name)
    return len(encoding.encode(string))

# Helper to chunk PDF
def extract_text_from_pdf(file_path):
    try:
        chunks = []
        with pdfplumber.open(file_path) as pdf:
            for page in pdf.pages:
                text = page.extract_text()
                if text:
                    paragraphs = [p.strip() for p in text.split('\n') if p.strip()]
                    chunks.extend(paragraphs)
        return chunks
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error processing PDF: {str(e)}")

@app.post("/upload")
async def upload_pdf(file: UploadFile = File(...)):
    if not file.filename.endswith('.pdf'):
        raise HTTPException(status_code=400, detail="Only PDF files are allowed")
    
    temp_path = f"server/temp/temp_{uuid.uuid4()}.pdf"
    try:
        with open(temp_path, "wb") as f:
            f.write(await file.read())

        chunks = extract_text_from_pdf(temp_path)
        
        for chunk in chunks:
            embedding = model.encode([chunk])[0]
            chunk_id = str(uuid.uuid4())
            metadata = {
                "uploaded_at": datetime.datetime.now().isoformat(),
                "frequency": 1,
                "recency": 1.0,
                "source": file.filename
            }
            chunk_store[chunk_id] = {
                "text": chunk,
                "embedding": embedding,
                "metadata": metadata
            }
            embeddings_list.append(embedding)

        # Update nearest neighbors
        if embeddings_list:
            embeddings_array = np.array(embeddings_list)
            neighbors.fit(embeddings_array)

        # Save progress
        with open(STORE_PATH, "wb") as f:
            pickle.dump(chunk_store, f)
        np.save(EMBEDDINGS_PATH, np.array(embeddings_list))

        return {"message": "PDF processed and stored successfully."}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error processing file: {str(e)}")
    finally:
        if os.path.exists(temp_path):
            os.remove(temp_path)

@app.post("/ask")
async def ask_question(query: Query):
    if not query.query.strip():
        raise HTTPException(status_code=400, detail="Query cannot be empty")
    
    try:
        query_embedding = model.encode([query.query])[0]
        if not embeddings_list:
            raise HTTPException(status_code=400, detail="No documents have been uploaded yet")
            
        distances, indices = neighbors.kneighbors([query_embedding])

        responses = []
        context_passages = []
        total_tokens = 0
        for idx in indices[0]:
            chunk = list(chunk_store.values())[idx]
            metadata = chunk["metadata"]
            metadata["frequency"] += 1
            metadata["recency"] = 1.0
            responses.append({
                "text": chunk["text"],
                "metadata": metadata
            })

            chunk_text = chunk["text"]
            token_count = num_tokens_from_string(chunk_text)
            if total_tokens + token_count <= 1500:
                context_passages.append(chunk_text)
                total_tokens += token_count
            else:
                break

        combined_context = "\n".join(context_passages)
        prompt = f"Answer the question based on the context below:\n\nContext:\n{combined_context}\n\nQuestion: {query.query}\nAnswer:"

        llm_response = ""
        try:
            gemini_model = genai.GenerativeModel(
                "gemini-2.0-flash",
                generation_config={
                    "temperature": 0.7,
                    "top_p": 0.8,
                    "top_k": 40,
                    "max_output_tokens": 2048,
                },
                safety_settings=[
                    {
                        "category": "HARM_CATEGORY_HARASSMENT",
                        "threshold": "BLOCK_NONE",
                    },
                    {
                        "category": "HARM_CATEGORY_HATE_SPEECH",
                        "threshold": "BLOCK_NONE",
                    },
                    {
                        "category": "HARM_CATEGORY_SEXUALLY_EXPLICIT",
                        "threshold": "BLOCK_NONE",
                    },
                    {
                        "category": "HARM_CATEGORY_DANGEROUS_CONTENT",
                        "threshold": "BLOCK_NONE",
                    },
                ]
            )
            response = gemini_model.generate_content(
                prompt,
                generation_config={
                    "temperature": 0.7,
                    "top_p": 0.8,
                    "top_k": 40,
                    "max_output_tokens": 2048,
                }
            )
            llm_response = response.text
        except Exception as e:
            print(f"LLM Error: {str(e)}")
            llm_response = "I apologize, but I'm having trouble generating a response at the moment. Please try again in a few moments."

        # Save updated metadata
        with open(STORE_PATH, "wb") as f:
            pickle.dump(chunk_store, f)

        # Handle memory management
        threshold = 0.2
        to_dump = [k for k, v in chunk_store.items() if v["metadata"]["recency"] < threshold]
        dump_data = {k: chunk_store.pop(k) for k in to_dump}
        if dump_data:
            with open(DUMP_PATH, "ab") as f:
                pickle.dump(dump_data, f)

        return JSONResponse(content={
            "answers": responses,
            "llm_response": llm_response
        })
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error processing query: {str(e)}")

