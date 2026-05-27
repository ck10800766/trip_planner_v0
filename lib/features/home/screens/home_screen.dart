import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trip Planner'),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Anime Pilgrimage',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Plan your anime location visits',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              _HomeCard(
                icon: Icons.layers,
                title: 'View POIs',
                subtitle: 'Browse by region, anime, or tag',
                onTap: () => context.push('/pois'),
              ),
              const SizedBox(height: 12),
              _HomeCard(
                icon: Icons.calendar_month,
                title: 'Trip Calendar',
                subtitle: 'Schedule your visits',
                onTap: () => context.push('/calendar'),
              ),
              if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) ...[
                const SizedBox(height: 12),
                _HomeCard(
                  icon: Icons.camera_alt,
                  title: 'Anime Camera',
                  subtitle: 'AR photo overlay with reference',
                  onTap: () => context.push('/camera'),
                ),
              ],
              const SizedBox(height: 12),
              _HomeCard(
                icon: Icons.confirmation_number,
                title: 'Tickets',
                subtitle: 'QR codes & bookings',
                onTap: () => context.push('/tickets'),
              ),
              const SizedBox(height: 12),
              _HomeCard(
                icon: Icons.sync,
                title: 'Export / Import',
                subtitle: 'JSON sync between devices',
                onTap: () => context.push('/sync'),
              ),
            ],
          ),
        ),      
      ),
    );
  }
}

class _HomeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _HomeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: ListTile(
        leading: Icon(icon, color: theme.colorScheme.primary, size: 32),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
