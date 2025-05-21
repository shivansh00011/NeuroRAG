import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:file_picker/file_picker.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NeuroRAG',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.dark(
          background: Color(0xFF343541),
          surface: Color(0xFF444654),
          primary: Color(0xFF10A37F),
        ),
        useMaterial3: true,
      ),
      home: const ChatScreen(),
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({Key? key}) : super(key: key);

  @override
  _ChatScreenState createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final List<ChatMessage> _messages = [];
  bool _isLoading = false;
  bool _hasChatStarted = false;
  String _apiBaseUrl = 'http://127.0.0.1:8000'; // Change to your API URL

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NeuroRAG'),
        backgroundColor: Theme.of(context).colorScheme.background,
        actions: [
          IconButton(
            icon: const Icon(Icons.upload_file),
            onPressed: _uploadPDF,
            tooltip: 'Upload PDF',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _hasChatStarted
                ? ListView.builder(
                    padding: const EdgeInsets.all(8.0),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      return _messages[index];
                    },
                  )
                : Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'NeuroRAG',
                          style: TextStyle(
                            fontSize: 40,
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'PDF-based Question Answering System',
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.grey[400],
                          ),
                        ),
                        const SizedBox(height: 40),
                        SizedBox(
                          width: 300,
                          child: Text(
                            'Upload PDFs and ask questions about their content',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.grey[500],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
          if (_isLoading)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: LinearProgressIndicator(
                backgroundColor: Colors.grey[800],
                valueColor: AlwaysStoppedAnimation<Color>(
                    Theme.of(context).colorScheme.primary),
              ),
            ),
          Container(
            padding: const EdgeInsets.all(8.0),
            color: Theme.of(context).colorScheme.background,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: InputDecoration(
                      hintText: 'Ask a question about your PDFs...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20.0),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: Theme.of(context).colorScheme.surface,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16.0, vertical: 8.0),
                    ),
                    minLines: 1,
                    maxLines: 5,
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8.0),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _sendMessage,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _uploadPDF() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      withData: true,
    );

    if (result != null) {
      setState(() {
        _isLoading = true;
      });

      try {
        var request = http.MultipartRequest(
          'POST',
          Uri.parse('$_apiBaseUrl/upload'),
        );

        request.files.add(
          http.MultipartFile.fromBytes(
            'file',
            result.files.single.bytes!,
            filename: result.files.single.name,
          ),
        );

        var response = await request.send();
        var responseData = await response.stream.bytesToString();
        var decodedResponse = jsonDecode(responseData);

        setState(() {
          _isLoading = false;
        });

        if (response.statusCode == 200) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('PDF uploaded successfully!'),
              backgroundColor: Colors.green,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to upload PDF: ${decodedResponse['detail']}'),
              backgroundColor: Colors.red,
            ),
          );
        }
      } catch (e) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error uploading PDF: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _sendMessage() async {
    if (_controller.text.trim().isEmpty) return;

    String text = _controller.text;
    _controller.clear();

    setState(() {
      _hasChatStarted = true;
      _messages.add(UserMessage(text: text));
      _isLoading = true;
    });

    try {
      final response = await http.post(
        Uri.parse('$_apiBaseUrl/ask'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'query': text}),
      ).timeout(
        const Duration(seconds: 300), // 5 minutes timeout
        onTimeout: () {
          throw TimeoutException('The request timed out. Please try again.');
        },
      );

      if (response.statusCode == 200) {
        Map<String, dynamic> data = jsonDecode(response.body);
        String aiResponse = data['llm_response'] ?? 'No response found';
        List<dynamic> answers = data['answers'] ?? [];

        setState(() {
          _messages.add(AIMessage(
            text: aiResponse,
            sources: answers
                .map<String>((answer) => answer['text'].toString())
                .toList(),
          ));
          _isLoading = false;
        });
      } else {
        Map<String, dynamic> errorData = jsonDecode(response.body);
        String errorMessage = errorData['detail'] ?? 'Failed to get response from server';
        setState(() {
          _messages.add(AIMessage(
            text: 'Error: $errorMessage',
            isError: true,
          ));
          _isLoading = false;
        });
      }
    } on TimeoutException {
      setState(() {
        _messages.add(AIMessage(
          text: 'The request took too long to complete. Please try again with a simpler question or try again later.',
          isError: true,
        ));
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _messages.add(AIMessage(
          text: 'An error occurred: ${e.toString()}',
          isError: true,
        ));
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

abstract class ChatMessage extends StatelessWidget {
  final String text;

  const ChatMessage({Key? key, required this.text}) : super(key: key);
}

class UserMessage extends ChatMessage {
  const UserMessage({Key? key, required String text}) : super(key: key, text: text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10.0, horizontal: 16.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            backgroundColor: Colors.grey[700],
            child: const Icon(Icons.person, color: Colors.white),
          ),
          const SizedBox(width: 12.0),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 16.0),
            ),
          ),
        ],
      ),
    );
  }
}

class AIMessage extends ChatMessage {
  final List<String> sources;
  final bool isError;

  const AIMessage({
    Key? key,
    required String text,
    this.sources = const [],
    this.isError = false,
  }) : super(key: key, text: text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10.0, horizontal: 16.0),
      color: isError 
          ? Colors.red.withOpacity(0.1)
          : Theme.of(context).colorScheme.surface,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            backgroundColor: isError 
                ? Colors.red
                : Theme.of(context).colorScheme.primary,
            child: Icon(
              isError ? Icons.error : Icons.psychology,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 12.0),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text,
                  style: TextStyle(
                    fontSize: 16.0,
                    color: isError ? Colors.red : null,
                  ),
                ),
                if (sources.isNotEmpty && !isError) ...[
                  const SizedBox(height: 16.0),
                  ExpansionTile(
                    title: const Text(
                      'Sources',
                      style: TextStyle(fontSize: 14.0, color: Colors.grey),
                    ),
                    collapsedIconColor: Colors.grey,
                    iconColor: Colors.grey,
                    children: sources
                        .map((source) => ListTile(
                              title: Text(
                                source,
                                style: const TextStyle(
                                    fontSize: 14.0, color: Colors.grey),
                              ),
                            ))
                        .toList(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}