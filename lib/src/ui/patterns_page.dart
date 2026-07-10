import 'package:flutter/material.dart';

import '../models/trading.dart';
import '../state/app_controller.dart';

class PatternsPage extends StatelessWidget {
  const PatternsPage({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Row(
              children: [
                Text(
                  'Message Patterns',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.add),
                  label: const Text('Add Rule'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'These are regular expressions. If the Telegram wording changes, any AI assistant can help generate or adjust them from sample messages. Separate instructions joined by AND are evaluated as separate actions.',
              style: TextStyle(fontSize: 12.5, color: Colors.white54),
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < controller.patterns.length; i++)
              _PatternCard(
                index: i,
                rule: controller.patterns[i],
                onSave: (rule) => controller.updatePattern(i, rule),
              ),
          ],
        );
      },
    );
  }
}

class _PatternCard extends StatefulWidget {
  const _PatternCard({
    required this.index,
    required this.rule,
    required this.onSave,
  });

  final int index;
  final PatternRule rule;
  final ValueChanged<PatternRule> onSave;

  @override
  State<_PatternCard> createState() => _PatternCardState();
}

class _PatternCardState extends State<_PatternCard> {
  late final TextEditingController _name;
  late final TextEditingController _regex;
  late final TextEditingController _priority;
  late bool _enabled;
  late TradeKind _action;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.rule.name);
    _regex = TextEditingController(text: widget.rule.regex);
    _priority = TextEditingController(text: widget.rule.priority.toString());
    _enabled = widget.rule.enabled;
    _action = widget.rule.action;
  }

  @override
  void dispose() {
    _name.dispose();
    _regex.dispose();
    _priority.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: 'Name'),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: _priority,
                    decoration: const InputDecoration(labelText: 'Priority'),
                  ),
                ),
                const SizedBox(width: 12),
                DropdownButton<TradeKind>(
                  value: _action,
                  items: TradeKind.values
                      .map(
                        (kind) => DropdownMenuItem(
                          value: kind,
                          child: Text(kind.name),
                        ),
                      )
                      .toList(),
                  onChanged: (value) =>
                      setState(() => _action = value ?? _action),
                ),
                const SizedBox(width: 12),
                Switch(
                  value: _enabled,
                  onChanged: (value) => setState(() => _enabled = value),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _regex,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Regex'),
            ),
            if (widget.rule.name == 'add_usd' || widget.rule.name == 'add_btc')
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Supports ADDED or ADDING, optional LONG/SHORT, and optional LIMIT TRIGGER AT price. Example: ADDED \$5000 AND ADDING \$5000 TO LIMIT TRIGGER AT 64,300.',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
              ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save),
                label: const Text('Save Rule'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _save() {
    widget.onSave(
      PatternRule(
        name: _name.text,
        regex: _regex.text,
        action: _action,
        priority: int.tryParse(_priority.text) ?? widget.rule.priority,
        enabled: _enabled,
      ),
    );
  }
}
