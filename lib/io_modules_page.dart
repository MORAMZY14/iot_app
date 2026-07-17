import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'app_constants.dart';

class IoModulesPage extends StatefulWidget {
  const IoModulesPage({super.key});

  @override
  State<IoModulesPage> createState() => _IoModulesPageState();
}

class _IoModulesPageState extends State<IoModulesPage> {
  static const _purple = Color(0xFF6C63FF);
  bool _loading = true;
  bool _saving = false;
  String? _error;
  final Map<int, Map<String, dynamic>> _buses = {};
  final List<Map<String, dynamic>> _modules = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Map<String, dynamic> _defaultHardware() => {
        'i2cBuses': {
          'bus0': {
            'id': 0,
            'sda': 21,
            'scl': 22,
            'frequency': 100000,
            'enabled': true,
          },
          'bus1': {
            'id': 1,
            'sda': 4,
            'scl': 14,
            'frequency': 100000,
            'enabled': false,
          },
        },
        'ioModules': {
          'io_1': {
            'id': 'io_1',
            'name': 'I/O Module 1',
            'type': 'PCF8574',
            'busId': 0,
            'address': 32,
            'channels': 8,
            'activeLow': true,
            'enabled': true,
          },
        },
      };

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) throw StateError('User is not signed in');
      final response = await http
          .get(Uri.parse('${AppConfig.databaseUrl}/smartHome/$uid/hardware.json'))
          .timeout(AppConfig.mediumTimeout);
      Map<String, dynamic> hardware = _defaultHardware();
      if (response.statusCode == 200 && response.body.isNotEmpty && response.body != 'null') {
        final decoded = jsonDecode(response.body);
        if (decoded is Map) hardware = decoded.cast<String, dynamic>();
      }
      _applyLocal(hardware);
    } catch (e) {
      _applyLocal(_defaultHardware());
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _applyLocal(Map<String, dynamic> hardware) {
    _buses.clear();
    _modules.clear();

    final rawBuses = hardware['i2cBuses'];
    if (rawBuses is Map) {
      for (final entry in rawBuses.entries) {
        if (entry.value is! Map) continue;
        final map = Map<String, dynamic>.from(entry.value as Map);
        final id = (map['id'] as num?)?.toInt() ??
            int.tryParse(entry.key.toString().replaceAll(RegExp(r'\D'), '')) ??
            0;
        _buses[id] = {
          'id': id,
          'sda': (map['sda'] as num?)?.toInt() ?? (id == 0 ? 21 : 4),
          'scl': (map['scl'] as num?)?.toInt() ?? (id == 0 ? 22 : 14),
          'frequency': (map['frequency'] as num?)?.toInt() ?? 100000,
          'enabled': map['enabled'] != false,
        };
      }
    }
    _buses.putIfAbsent(0, () => {'id': 0, 'sda': 21, 'scl': 22, 'frequency': 100000, 'enabled': true});
    _buses.putIfAbsent(1, () => {'id': 1, 'sda': 4, 'scl': 14, 'frequency': 100000, 'enabled': false});

    final rawModules = hardware['ioModules'] ?? hardware['expanders'];
    if (rawModules is Map) {
      for (final entry in rawModules.entries) {
        if (entry.value is! Map) continue;
        final map = Map<String, dynamic>.from(entry.value as Map);
        _modules.add({
          'id': (map['id'] ?? entry.key).toString(),
          'name': (map['name'] ?? entry.key).toString(),
          'type': 'PCF8574',
          'busId': (map['busId'] as num?)?.toInt() ?? 0,
          'address': (map['address'] as num?)?.toInt() ?? 32,
          'channels': 8,
          'activeLow': map['activeLow'] != false,
          'enabled': map['enabled'] != false,
          'ready': map['ready'],
        });
      }
    }
    if (_modules.isEmpty) {
      _modules.add(Map<String, dynamic>.from(
        (_defaultHardware()['ioModules'] as Map)['io_1'] as Map,
      ));
    }
    _modules.sort((a, b) => a['name'].toString().compareTo(b['name'].toString()));
  }

  Map<String, dynamic> _toHardwareJson() {
    final buses = <String, dynamic>{};
    for (final entry in _buses.entries) {
      buses['bus${entry.key}'] = Map<String, dynamic>.from(entry.value);
    }
    final modules = <String, dynamic>{};
    for (final module in _modules) {
      modules[module['id'].toString()] = {
        'id': module['id'],
        'name': module['name'],
        'type': 'PCF8574',
        'busId': module['busId'],
        'address': module['address'],
        'channels': 8,
        'activeLow': module['activeLow'] != false,
        'enabled': module['enabled'] != false,
      };
    }
    return {'i2cBuses': buses, 'ioModules': modules};
  }

  bool _validPin(int pin) {
    if (pin < 0 || pin > 33) return false;
    if (pin >= 6 && pin <= 11) return false;
    if (pin == 15) return false;
    return true;
  }

  String? _validateAll() {
    if (_modules.isEmpty) return 'Add at least one I/O module.';
    if (_modules.length > 16) return 'This firmware supports up to 16 I/O modules.';
    for (final bus in _buses.values) {
      if (bus['enabled'] != true) continue;
      final sda = bus['sda'] as int;
      final scl = bus['scl'] as int;
      if (!_validPin(sda) || !_validPin(scl) || sda == scl) {
        return 'Bus ${bus['id']} has invalid SDA/SCL pins.';
      }
    }
    final enabledBuses = _buses.values.where((bus) => bus['enabled'] == true).toList();
    for (var i = 0; i < enabledBuses.length; i++) {
      for (var j = i + 1; j < enabledBuses.length; j++) {
        final firstPins = {enabledBuses[i]['sda'], enabledBuses[i]['scl']};
        final secondPins = {enabledBuses[j]['sda'], enabledBuses[j]['scl']};
        if (firstPins.intersection(secondPins).isNotEmpty) {
          return 'Bus ${enabledBuses[i]['id']} and Bus ${enabledBuses[j]['id']} cannot share a GPIO.';
        }
      }
    }

    final seen = <String>{};
    for (final module in _modules) {
      if (module['enabled'] == false) continue;
      final busId = module['busId'] as int;
      final address = module['address'] as int;
      if (!_buses.containsKey(busId) || _buses[busId]!['enabled'] != true) {
        return '${module['name']} uses a disabled or invalid bus.';
      }
      if (!((address >= 0x20 && address <= 0x27) || (address >= 0x38 && address <= 0x3F))) {
        return '${module['name']} has an invalid PCF8574 address.';
      }
      final key = '$busId:$address';
      if (!seen.add(key)) return 'Two modules cannot use the same address on the same bus.';
    }
    return null;
  }

  Future<String?> _espIp(String uid) async {
    try {
      final response = await http
          .get(Uri.parse('${AppConfig.databaseUrl}/smartHome/$uid/status/ip.json'))
          .timeout(AppConfig.shortTimeout);
      if (response.statusCode == 200 && response.body != 'null') {
        return jsonDecode(response.body)?.toString();
      }
    } catch (_) {}
    return null;
  }

  Future<void> _save() async {
    final validation = _validateAll();
    if (validation != null) {
      _snack(validation, Colors.orange);
      return;
    }
    setState(() => _saving = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) throw StateError('User is not signed in');
      final hardware = _toHardwareJson();
      final response = await http
          .put(
            Uri.parse('${AppConfig.databaseUrl}/smartHome/$uid/hardware.json'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(hardware),
          )
          .timeout(AppConfig.mediumTimeout);
      if (response.statusCode != 200) throw StateError('Firebase returned ${response.statusCode}');

      final ip = await _espIp(uid);
      if (ip != null && ip.isNotEmpty) {
        try {
          await http
              .post(
                Uri.parse('http://$ip/api/io/modules/save'),
                headers: const {'Content-Type': 'application/json'},
                body: jsonEncode(hardware),
              )
              .timeout(AppConfig.mediumTimeout);
        } catch (_) {
          // Firmware also polls Firebase, so local reachability is optional.
        }
      }
      if (mounted) _snack('I/O module configuration saved.', const Color(0xFF25B36A));
    } catch (e) {
      if (mounted) _snack('Could not save: $e', Colors.redAccent);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _moduleUsed(String moduleId) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return false;
    try {
      final response = await http
          .get(Uri.parse('${AppConfig.databaseUrl}/smartHome/$uid/devices.json'))
          .timeout(AppConfig.shortTimeout);
      if (response.statusCode == 200 && response.body != 'null') {
        final decoded = jsonDecode(response.body);
        if (decoded is Map) {
          return decoded.values.whereType<Map>().any(
                (d) => (d['moduleId'] ?? d['expanderId'] ?? 'io_1').toString() == moduleId,
              );
        }
      }
    } catch (_) {}
    return false;
  }

  Future<void> _deleteModule(Map<String, dynamic> module) async {
    if (await _moduleUsed(module['id'].toString())) {
      _snack('Move or delete devices assigned to this module first.', Colors.orange);
      return;
    }
    setState(() => _modules.removeWhere((m) => m['id'] == module['id']));
  }

  Future<void> _openEditor([Map<String, dynamic>? existing]) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ModuleEditor(
        existing: existing,
        buses: _buses,
        moduleCount: _modules.length,
      ),
    );
    if (result == null || !mounted) return;

    final busId = result['busId'] as int;
    final bus = Map<String, dynamic>.from(result.remove('bus') as Map);
    _buses[busId] = bus;
    final index = _modules.indexWhere((m) => m['id'] == result['id']);
    setState(() {
      if (index >= 0) {
        _modules[index] = result;
      } else {
        _modules.add(result);
      }
      _buses[busId]!['enabled'] = true;
    });
  }

  void _snack(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: color, behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('I/O Modules'),
        actions: [
          IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _saving ? null : () => _openEditor(),
        backgroundColor: _purple,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Module'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
              children: [
                if (_error != null)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text('Loaded defaults because cloud settings were unavailable.\n$_error'),
                    ),
                  ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'The ESP32 has two hardware I²C controllers. A module can use Bus 0 or Bus 1. '
                      'To add more than two PCF8574 boards, share a bus and give each board a different A0/A1/A2 address.',
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                for (final module in _modules) ...[
                  _moduleCard(module),
                  const SizedBox(height: 10),
                ],
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_rounded),
                  label: Text(_saving ? 'Saving…' : 'Save & Apply'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), backgroundColor: _purple),
                ),
              ],
            ),
    );
  }

  Widget _moduleCard(Map<String, dynamic> module) {
    final busId = module['busId'] as int;
    final bus = _buses[busId]!;
    final address = module['address'] as int;
    final ready = module['ready'];
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        leading: CircleAvatar(
          backgroundColor: _purple.withValues(alpha: 0.14),
          child: const Icon(Icons.hub_rounded, color: _purple),
        ),
        title: Text(module['name'].toString(), style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          '${module['id']} • Bus $busId • SDA ${bus['sda']} / SCL ${bus['scl']}\n'
          'Address 0x${address.toRadixString(16).padLeft(2, '0').toUpperCase()} • 8 outputs${ready == null ? '' : ready == true ? ' • Online' : ' • Offline'}',
        ),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'edit') _openEditor(module);
            if (value == 'delete') _deleteModule(module);
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('Edit')),
            PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
        onTap: () => _openEditor(module),
      ),
    );
  }
}

class _ModuleEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final Map<int, Map<String, dynamic>> buses;
  final int moduleCount;

  const _ModuleEditor({required this.existing, required this.buses, required this.moduleCount});

  @override
  State<_ModuleEditor> createState() => _ModuleEditorState();
}

class _ModuleEditorState extends State<_ModuleEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _sda;
  late final TextEditingController _scl;
  late final TextEditingController _address;
  late int _busId;
  late bool _activeLow;
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _busId = (existing?['busId'] as num?)?.toInt() ?? (widget.moduleCount == 0 ? 0 : 1);
    final bus = widget.buses[_busId] ?? widget.buses[0]!;
    _name = TextEditingController(text: existing?['name']?.toString() ?? 'I/O Module ${widget.moduleCount + 1}');
    _sda = TextEditingController(text: bus['sda'].toString());
    _scl = TextEditingController(text: bus['scl'].toString());
    final address = (existing?['address'] as num?)?.toInt() ?? 32;
    _address = TextEditingController(text: '0x${address.toRadixString(16).toUpperCase()}');
    _activeLow = existing?['activeLow'] != false;
    _enabled = existing?['enabled'] != false;
  }

  void _selectBus(int value) {
    final bus = widget.buses[value]!;
    setState(() {
      _busId = value;
      _sda.text = bus['sda'].toString();
      _scl.text = bus['scl'].toString();
    });
  }

  int? _parseAddress(String value) {
    final text = value.trim().toLowerCase();
    return text.startsWith('0x') ? int.tryParse(text.substring(2), radix: 16) : int.tryParse(text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add I/O Module' : 'Edit I/O Module'),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Module name'),
                  validator: (v) => v == null || v.trim().isEmpty ? 'Enter a name' : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  value: _busId,
                  decoration: const InputDecoration(labelText: 'Hardware I²C bus'),
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('Bus 0')),
                    DropdownMenuItem(value: 1, child: Text('Bus 1')),
                  ],
                  onChanged: (v) => v == null ? null : _selectBus(v),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _sda,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'SDA GPIO'),
                        validator: (v) => int.tryParse(v ?? '') == null ? 'Invalid' : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _scl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'SCL GPIO'),
                        validator: (v) => int.tryParse(v ?? '') == null ? 'Invalid' : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _address,
                  decoration: const InputDecoration(labelText: 'PCF8574 address', hintText: '0x20'),
                  validator: (v) {
                    final address = _parseAddress(v ?? '');
                    if (address == null) return 'Enter an address';
                    if (!((address >= 0x20 && address <= 0x27) || (address >= 0x38 && address <= 0x3F))) {
                      return 'Use 0x20–0x27 or 0x38–0x3F';
                    }
                    return null;
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active-low relay module'),
                  value: _activeLow,
                  onChanged: (v) => setState(() => _activeLow = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Enabled'),
                  value: _enabled,
                  onChanged: (v) => setState(() => _enabled = v),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            final id = widget.existing?['id']?.toString() ?? 'io_${DateTime.now().millisecondsSinceEpoch}';
            Navigator.pop(context, {
              'id': id,
              'name': _name.text.trim(),
              'type': 'PCF8574',
              'busId': _busId,
              'address': _parseAddress(_address.text)!,
              'channels': 8,
              'activeLow': _activeLow,
              'enabled': _enabled,
              'bus': {
                'id': _busId,
                'sda': int.parse(_sda.text),
                'scl': int.parse(_scl.text),
                'frequency': 100000,
                'enabled': true,
              },
            });
          },
          child: const Text('Done'),
        ),
      ],
    );
  }
}
