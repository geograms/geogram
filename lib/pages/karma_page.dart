import 'package:flutter/material.dart';

import '../api/api.dart';
import '../server/karma/karma_engine.dart';
import '../server/karma/karma_models.dart';
import '../services/profile_service.dart';
/// Karma gamification dashboard page.
/// Shows user's level, streak, daily progress, category cards, and leaderboard.
class KarmaPage extends StatefulWidget {
  const KarmaPage({super.key});

  @override
  State<KarmaPage> createState() => _KarmaPageState();
}

class _KarmaPageState extends State<KarmaPage> {
  final GeogramApi _api = GeogramApi();

  KarmaProfile? _profile;
  List<LeaderboardEntry> _leaderboard = [];
  bool _loading = true;
  String _leaderboardPeriod = 'weekly';
  int _todayPoints = 0;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  String get _callsign => ProfileService().getProfile().callsign;

  Future<void> _loadData() async {
    setState(() => _loading = true);
    try {
      final profileResp = await _api.karma.profile(_callsign);
      final leaderboardResp = await _api.karma.leaderboard(
        _callsign, period: _leaderboardPeriod, limit: 20,
      );

      if (mounted) {
        setState(() {
          if (profileResp.data != null) {
            _profile = profileResp.data;
            _todayPoints = (profileResp.rawData as Map<String, dynamic>?)?['today_points'] as int? ?? 0;
          }
          if (leaderboardResp.data != null) {
            _leaderboard = leaderboardResp.data!;
          }
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Karma'),
        actions: [
          if (_profile != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Chip(
                avatar: const Icon(Icons.leaderboard, size: 16),
                label: Text('#${_profile!.rank > 0 ? _profile!.rank : '—'}'),
              ),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadData,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _buildProfileHeader(theme),
                  const SizedBox(height: 16),
                  _buildTodayScore(theme),
                  const SizedBox(height: 16),
                  _buildCategoryCards(theme),
                  const SizedBox(height: 24),
                  _buildLeaderboardSection(theme),
                ],
              ),
            ),
    );
  }

  Widget _buildProfileHeader(ThemeData theme) {
    final profile = _profile;
    if (profile == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Text('No karma data yet. Start earning points!',
                style: theme.textTheme.bodyLarge),
          ),
        ),
      );
    }

    final nextLevel = KarmaEngine.pointsToNextLevel(profile.totalPoints);
    final currentLevelPoints = KarmaEngine.computeLevel(profile.totalPoints).pointsRequired;
    final progressToNext = nextLevel != null
        ? (profile.totalPoints - currentLevelPoints) / (nextLevel - currentLevelPoints)
        : 1.0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // Level badge
            Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      'Lv${profile.level}',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile.levelName,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '${profile.totalPoints} total points',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Progress bar to next level
            if (nextLevel != null) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('${profile.totalPoints}', style: theme.textTheme.bodySmall),
                  Text('$nextLevel', style: theme.textTheme.bodySmall),
                ],
              ),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progressToNext.clamp(0.0, 1.0),
                  minHeight: 8,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Next: ${KarmaEngine.levels.firstWhere((l) => l.pointsRequired == nextLevel, orElse: () => KarmaEngine.levels.last).name}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],

            const SizedBox(height: 12),

            // Streak info
            Row(
              children: [
                Icon(Icons.local_fire_department,
                    color: profile.currentStreakDays >= 7
                        ? Colors.orange
                        : theme.colorScheme.onSurfaceVariant,
                    size: 20),
                const SizedBox(width: 4),
                Text(
                  '${profile.currentStreakDays}-day streak',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${profile.currentMultiplier}x multiplier',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onTertiaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTodayScore(ThemeData theme) {
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Row(
          children: [
            Icon(Icons.today, color: theme.colorScheme.onPrimaryContainer),
            const SizedBox(width: 12),
            Text(
              "Today's Score: $_todayPoints pts",
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryCards(ThemeData theme) {
    final categories = [
      _CategoryInfo('Chat', Icons.chat, 'chat_message', 2, 50, 'chat'),
      _CategoryInfo('Blog', Icons.article, 'blog_published', 50, 3, 'blog'),
      _CategoryInfo('Places', Icons.place, 'place_created', 30, 5, 'places'),
      _CategoryInfo('Alerts', Icons.campaign, 'alert_created', 25, 5, 'alerts'),
      _CategoryInfo('Social', Icons.favorite, 'like_given', 2, 30, null),
      _CategoryInfo('Events', Icons.event, 'event_created', 30, 3, 'events'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('EARN POINTS', style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
          color: theme.colorScheme.onSurfaceVariant,
        )),
        const SizedBox(height: 8),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            childAspectRatio: 1.6,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: categories.length,
          itemBuilder: (context, index) {
            return _buildCategoryCard(theme, categories[index]);
          },
        ),
      ],
    );
  }

  Widget _buildCategoryCard(ThemeData theme, _CategoryInfo cat) {
    final todayCount = _profile?.actionCountsToday[cat.actionKey] ?? 0;
    final progress = cat.dailyCap > 0 ? (todayCount / cat.dailyCap).clamp(0.0, 1.0) : 0.0;

    return Card(
      child: InkWell(
        onTap: cat.navigateTo != null ? () => _navigateToApp(cat.navigateTo!) : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(cat.icon, size: 20, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(cat.name,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis),
                  ),
                  Text('+${cat.pointsPer}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      )),
                ],
              ),
              const Spacer(),
              Text('$todayCount/${cat.dailyCap} today',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  )),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLeaderboardSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('LEADERBOARD', style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: theme.colorScheme.onSurfaceVariant,
            )),
            const Spacer(),
            _buildPeriodChip('weekly'),
            const SizedBox(width: 4),
            _buildPeriodChip('monthly'),
            const SizedBox(width: 4),
            _buildPeriodChip('alltime'),
          ],
        ),
        const SizedBox(height: 8),
        if (_leaderboard.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text('No leaderboard data yet',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  )),
            ),
          )
        else
          Card(
            child: Column(
              children: [
                for (final entry in _leaderboard)
                  _buildLeaderboardRow(theme, entry),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildPeriodChip(String period) {
    final isSelected = period == _leaderboardPeriod;
    final label = period == 'alltime' ? 'All' : period[0].toUpperCase() + period.substring(1);

    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      selected: isSelected,
      onSelected: (selected) {
        if (selected) {
          setState(() => _leaderboardPeriod = period);
          _loadData();
        }
      },
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
    );
  }

  Widget _buildLeaderboardRow(ThemeData theme, LeaderboardEntry entry) {
    final isYou = entry.callsign.toUpperCase() == _callsign.toUpperCase();

    return Container(
      decoration: BoxDecoration(
        color: isYou ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3) : null,
        border: Border(
          bottom: BorderSide(color: theme.dividerColor.withValues(alpha: 0.2)),
        ),
      ),
      child: ListTile(
        dense: true,
        leading: SizedBox(
          width: 32,
          child: Center(
            child: Text(
              '${entry.rank}',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: entry.rank <= 3
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurface,
              ),
            ),
          ),
        ),
        title: Text(
          '${entry.callsign}${isYou ? "  (YOU)" : ""}',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: isYou ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        subtitle: Text(entry.levelName,
            style: theme.textTheme.bodySmall),
        trailing: Text(
          '${entry.points} pts',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  void _navigateToApp(String appType) {
    // Pop back to home and the user can navigate to the app from there
    Navigator.of(context).pop();
  }
}

class _CategoryInfo {
  final String name;
  final IconData icon;
  final String actionKey;
  final int pointsPer;
  final int dailyCap;
  final String? navigateTo;

  const _CategoryInfo(this.name, this.icon, this.actionKey, this.pointsPer, this.dailyCap, this.navigateTo);
}
