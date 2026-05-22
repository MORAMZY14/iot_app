import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class ProvisioningPage extends StatefulWidget {
  const ProvisioningPage({super.key});

  @override
  State<ProvisioningPage> createState() => _ProvisioningPageState();
}

class _ProvisioningPageState extends State<ProvisioningPage> {
  List<dynamic> _networks = [];
  bool _isLoading = true;
  String? _error;
  final TextEditingController _passwordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetchNetworks();
  }

  Future<void> _fetchNetworks() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final response = await http.get(
        Uri.parse('http://192.168.4.1/scan'),
        headers: {'Content-Type': 'application/json'},
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _networks = data['networks'] ?? [];
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = 'Scan failed (code ${response.statusCode})';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Cannot reach ESP32.\n'
            'Make sure you are connected to the "ESP32_Config" Wi‑Fi.';
        _isLoading = false;
      });
    }
  }

  Future<void> _sendCredentials(String ssid) async {
    final password = _passwordController.text.trim();
    if (password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter the Wi‑Fi password')),
      );
      return;
    }
    try {
      final response = await http.post(
        Uri.parse('http://192.168.4.1/save'),
        body: {'ssid': ssid, 'pass': password},
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Credentials sent. ESP32 will now reboot.')),
        );
        Navigator.pop(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed (code ${response.statusCode})')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Provision ESP32'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchNetworks,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _fetchNetworks,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      )
          : ListView.builder(
        itemCount: _networks.length,
        itemBuilder: (context, index) {
          final net = _networks[index];
          final ssid = net['ssid'] as String;
          final rssi = net['rssi'] as int;
          final encryption = net['encryption'] as String? ?? 'secured';
          return ListTile(
            title: Text(ssid),
            subtitle: Text('$rssi dBm · $encryption'),
            trailing: const Icon(Icons.arrow_forward_ios),
            onTap: () {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text('Connect to $ssid'),
                  content: TextField(
                    controller: _passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Password',
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel'),
                    ),
                    ElevatedButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _sendCredentials(ssid);
                      },
                      child: const Text('Connect'),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}