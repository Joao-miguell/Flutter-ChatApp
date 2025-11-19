import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class CreateGroupDialog extends StatefulWidget {
  const CreateGroupDialog({super.key});

  @override
  State<CreateGroupDialog> createState() => _CreateGroupDialogState();
}

class _CreateGroupDialogState extends State<CreateGroupDialog> {
  final supabase = Supabase.instance.client;
  final TextEditingController _ctrl = TextEditingController();

  String _name = "";
  List<Map<String, dynamic>> _found = [];
  List<String> _selected = [];
  bool _loading = false;
  bool _isPublic = true; 

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _found = []);
      return;
    }

    setState(() => _loading = true);

    try {
      final myId = supabase.auth.currentUser!.id;

      final result = await supabase
          .from('profiles')
          .select('id, name, avatar_url')
          .like('name', '%$query%')
          .neq('id', myId);

      setState(() => _found = result);
    } catch (e) {
      debugPrint("Erro ao buscar usuários: $e");
    }

    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Criar Grupo'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              decoration: const InputDecoration(labelText: 'Nome do grupo'),
              onChanged: (v) => _name = v,
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              title: const Text("Grupo Público"),
              subtitle: Text(_isPublic 
                  ? "Qualquer um pode entrar." 
                  : "Requer aprovação para entrar."),
              value: _isPublic,
              onChanged: (val) {
                setState(() {
                  _isPublic = val;
                });
              },
              contentPadding: EdgeInsets.zero,
            ),
            const Divider(),
            TextField(
              controller: _ctrl,
              decoration: const InputDecoration(
                labelText: 'Adicionar participantes (buscar)',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: _search,
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(12),
                child: CircularProgressIndicator(),
              )
            else
              SizedBox(
                width: double.maxFinite, 
                height: 200,
                child: ListView.builder(
                  itemCount: _found.length,
                  itemBuilder: (context, index) {
                    final user = _found[index];
                    final id = user['id'] as String;
                    final name = user['name'] ?? 'Usuário';
                    final avatar = user['avatar_url'] as String?;
                    final selected = _selected.contains(id);

                    return ListTile(
                      leading: CircleAvatar(
                        backgroundImage: avatar != null ? NetworkImage(avatar) : null,
                        child: avatar == null ? Text(name[0].toUpperCase()) : null,
                      ),
                      title: Text(name),
                      trailing: IconButton(
                        icon: Icon(
                          selected ? Icons.check_box : Icons.check_box_outline_blank,
                        ),
                        onPressed: () {
                          setState(() {
                            if (selected) {
                              _selected.remove(id);
                            } else {
                              _selected.add(id);
                            }
                          });
                        },
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: () {
            if (_name.trim().isEmpty || _selected.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Digite um nome e selecione ao menos 1 participante.'),
                ),
              );
              return;
            }

            Navigator.of(context).pop({
              'name': _name.trim(),
              'participants': _selected,
              'is_public': _isPublic,
            });
          },
          child: const Text('Criar'),
        ),
      ],
    );
  }
}
