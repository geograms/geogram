import 'package:flutter/material.dart';

import '../pages/blog_browser_page.dart';
import '../pages/chat_browser_page.dart';
import '../pages/events_browser_page.dart';
import '../pages/places_browser_page.dart';
import '../pages/report_browser_page.dart';
import '../server/karma/karma_engine.dart';
import '../server/karma/karma_models.dart';
import '../services/app_service.dart';
import '../services/profile_service.dart';
import '../services/station_server_service.dart';
import '../util/event_bus.dart';

/// Karma gamification dashboard page.
/// 3-tab layout: Today (daily missions), Stats, Leaderboard.
class KarmaPage extends StatefulWidget {
  const KarmaPage({super.key});

  @override
  State<KarmaPage> createState() => _KarmaPageState();
}

class _KarmaPageState extends State<KarmaPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  KarmaProfile? _profile;
  List<LeaderboardEntry> _leaderboard = [];
  bool _loading = true;
  String _leaderboardPeriod = 'weekly';
  int _myRank = 0;

  static const _missions = KarmaEngine.missions;

  static const _missionIcons = <String, IconData>{
    'Chat': Icons.chat,
    'Blog': Icons.article,
    'Places': Icons.place,
    'Alerts': Icons.campaign,
    'Social': Icons.favorite,
    'Events': Icons.event,
  };

  EventSubscription<KarmaUpdatedEvent>? _karmaSubscription;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadData();
    _karmaSubscription = EventBus().on<KarmaUpdatedEvent>((event) {
      if (event.callsign.toUpperCase() == _callsign.toUpperCase()) {
        _loadData();
      }
    });
  }

  @override
  void dispose() {
    _karmaSubscription?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  String get _callsign => ProfileService().getProfile().callsign;

  Future<void> _loadData() async {
    setState(() => _loading = true);
    try {
      final cs = _callsign.toUpperCase();
      final store = StationServerService().karmaStore;

      // Read profile directly from local karma store
      var profile = await store.readProfile(cs);
      if (profile == null) {
        // Build fresh profile from local data
        final streak = await store.readStreak(cs);
        final todayCounts = await store.getTodayActionCounts(cs);
        final events = await store.readEvents(cs, limit: 10000);
        final totalPoints = events.fold<int>(0, (sum, e) => sum + e.pointsFinal);
        profile = KarmaEngine.buildProfile(
          callsign: cs,
          totalPoints: totalPoints,
          streak: streak,
          actionCountsToday: todayCounts,
        );
      }

      // Read leaderboard
      final leaderboardEntries = await store.readLeaderboard(_leaderboardPeriod);

      if (mounted) {
        setState(() {
          _profile = profile;
          _leaderboard = leaderboardEntries;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
    // Load rank independently so profile errors can't prevent it
    try {
      final store = StationServerService().karmaStore;
      final cs = _callsign.toUpperCase();
      final alltime = await store.readLeaderboard('alltime');
      for (final entry in alltime) {
        if (entry.callsign.toUpperCase() == cs) {
          if (mounted) setState(() => _myRank = entry.rank);
          break;
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Karma'),
        actions: [
          if (_myRank > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Chip(
                avatar: const Icon(Icons.leaderboard, size: 16),
                label: Text('#$_myRank'),
              ),
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Today'),
            Tab(text: 'Stats'),
            Tab(text: 'Leaderboard'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildTodayTab(theme),
                _buildStatsTab(theme),
                _buildLeaderboardTab(theme),
              ],
            ),
    );
  }

  // ==================== Tab 1: Today ====================

  Widget _buildTodayTab(ThemeData theme) {
    final profile = _profile;
    final counts = profile?.actionCountsToday ?? {};

    // Count active (started) and completed missions
    int activeMissions = 0;
    int totalMaxPoints = 0;
    int totalEarnedPoints = 0;
    for (final m in _missions) {
      final earned = m.todayEarned(counts);
      final max = m.maxDailyPoints;
      totalMaxPoints += max;
      totalEarnedPoints += earned;
      if (earned > 0) activeMissions++;
    }
    // Add diversity bonus max
    final diversityConfig = KarmaEngine.actions['feature_diversity'];
    final diversityMax = diversityConfig != null ? diversityConfig.points * diversityConfig.dailyCap : 15;
    totalMaxPoints += diversityMax;
    final diversityEarned = counts['feature_diversity'] ?? 0;
    totalEarnedPoints += (diversityEarned > 0 ? diversityMax : 0);

    final overallProgress = totalMaxPoints > 0 ? totalEarnedPoints / totalMaxPoints : 0.0;

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildTodaySummaryBar(theme, totalEarnedPoints, totalMaxPoints),
          const SizedBox(height: 12),
          _buildDailyCompletionMeter(theme, activeMissions, overallProgress),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('DAILY MISSIONS', style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: theme.colorScheme.onSurfaceVariant,
            )),
          ),
          for (final mission in _missions) ...[
            _buildMissionCard(theme, mission, counts),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 4),
          _buildBonusMissionCard(theme, counts),
        ],
      ),
    );
  }

  Widget _buildTodaySummaryBar(ThemeData theme, int earnedPoints, int maxPoints) {
    final profile = _profile;

    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Row(
          children: [
            Text(
              '$earnedPoints',
              style: theme.textTheme.headlineLarge?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'points today out of $maxPoints',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const Spacer(),
            if (profile != null && profile.currentStreakDays > 0) ...[
              Icon(Icons.local_fire_department,
                  color: profile.currentStreakDays >= 7
                      ? Colors.orange
                      : theme.colorScheme.onPrimaryContainer,
                  size: 20),
              const SizedBox(width: 2),
              Text(
                '${profile.currentStreakDays}d',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 10),
            ],
            if (profile != null && profile.currentMultiplier > 1.0) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${profile.currentMultiplier}x',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onTertiaryContainer,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 10),
            ],
            if (_myRank > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.leaderboard, size: 14,
                        color: theme.colorScheme.onSecondaryContainer),
                    const SizedBox(width: 4),
                    Text(
                      '#$_myRank',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDailyCompletionMeter(ThemeData theme, int activeMissions, double progress) {
    final pct = (progress * 100).round();

    return Column(
      children: [
        Row(
          children: [
            Text(
              '$activeMissions/${_missions.length} missions active',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            Text(
              '$pct%',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: progress.clamp(0.0, 1.0),
            minHeight: 10,
          ),
        ),
      ],
    );
  }

  Widget _buildMissionCard(ThemeData theme, KarmaMission mission, Map<String, int> counts) {
    final earned = mission.todayEarned(counts);
    final max = mission.maxDailyPoints;
    final progress = mission.progress(counts);
    final complete = mission.isComplete(counts);

    return Card(
      clipBehavior: Clip.antiAlias,
      color: complete
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
          : null,
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: complete
                ? Colors.green.withValues(alpha: 0.15)
                : theme.colorScheme.surfaceContainerHighest,
            shape: BoxShape.circle,
          ),
          child: Icon(
            complete ? Icons.check : (_missionIcons[mission.name] ?? Icons.star),
            color: complete ? Colors.green : theme.colorScheme.primary,
            size: 22,
          ),
        ),
        title: Text(
          mission.verb,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
            decoration: complete ? TextDecoration.lineThrough : null,
            color: complete ? theme.colorScheme.onSurfaceVariant : null,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: progress.clamp(0.0, 1.0),
                minHeight: 6,
                color: complete ? Colors.green : null,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '$earned/$max points',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        trailing: complete
            ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'DONE',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.green,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              )
            : Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '+$max',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
        children: [
          Text(
            mission.description,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (mission.navigateTo != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _navigateToApp(mission.navigateTo!),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: Text('Open ${mission.name}'),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBonusMissionCard(ThemeData theme, Map<String, int> counts) {
    final categoriesUsed = <String>{};
    for (final entry in counts.entries) {
      final config = KarmaEngine.actions[entry.key];
      if (config != null && entry.value > 0 && config.category != 'bonus') {
        categoriesUsed.add(config.category);
      }
    }

    final required = KarmaEngine.diversityCategoriesRequired;
    final earned = counts['feature_diversity'] ?? 0;
    final complete = earned > 0;
    final diversityConfig = KarmaEngine.actions['feature_diversity'];
    final bonusPoints = diversityConfig?.points ?? 15;

    // Category icons for the visual indicator
    const categoryIcons = {
      'connection': Icons.login,
      'chat': Icons.chat,
      'content': Icons.create,
      'social': Icons.people,
      'passive': Icons.inbox,
    };

    return Card(
      color: complete
          ? theme.colorScheme.tertiaryContainer.withValues(alpha: 0.3)
          : theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: complete
                    ? Colors.green.withValues(alpha: 0.15)
                    : theme.colorScheme.tertiaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                complete ? Icons.check : Icons.stars,
                color: complete ? Colors.green : theme.colorScheme.tertiary,
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Feature Diversity Bonus',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      decoration: complete ? TextDecoration.lineThrough : null,
                      color: complete
                          ? theme.colorScheme.onSurfaceVariant
                          : null,
                    ),
                  ),
                  const SizedBox(height: 6),
                  // Category icons row
                  Row(
                    children: categoryIcons.entries.map((e) {
                      final lit = categoriesUsed.contains(e.key);
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Icon(
                          e.value,
                          size: 18,
                          color: lit
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Use $required+ categories today',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (complete)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'EARNED',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.green,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '+$bonusPoints',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onTertiaryContainer,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ==================== Tab 2: Stats ====================

  Widget _buildStatsTab(ThemeData theme) {
    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildProfileHeader(theme),
          const SizedBox(height: 16),
          _buildStreakDetails(theme),
        ],
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

  Widget _buildStreakDetails(ThemeData theme) {
    final profile = _profile;
    if (profile == null) return const SizedBox.shrink();

    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      childAspectRatio: 1.8,
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      children: [
        _buildStatTile(theme, Icons.local_fire_department, 'Current Streak',
            '${profile.currentStreakDays} days', Colors.orange),
        _buildStatTile(theme, Icons.speed, 'Multiplier',
            '${profile.currentMultiplier}x', theme.colorScheme.tertiary),
        _buildStatTile(theme, Icons.military_tech, 'Level',
            'Lv${profile.level} ${profile.levelName}', theme.colorScheme.primary),
        _buildStatTile(theme, Icons.star, 'Total Points',
            '${profile.totalPoints}', Colors.amber),
      ],
    );
  }

  Widget _buildStatTile(ThemeData theme, IconData icon, String label, String value, Color iconColor) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: iconColor),
                const SizedBox(width: 6),
                Text(label, style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                )),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  // ==================== Tab 3: Leaderboard ====================

  Widget _buildLeaderboardTab(ThemeData theme) {
    return RefreshIndicator(
      onRefresh: _loadData,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                _buildPeriodChip('weekly'),
                const SizedBox(width: 4),
                _buildPeriodChip('monthly'),
                const SizedBox(width: 4),
                _buildPeriodChip('alltime'),
              ],
            ),
          ),
          Expanded(
            child: _leaderboard.isEmpty
                ? ListView(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(48),
                        child: Center(
                          child: Text('No leaderboard data yet',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              )),
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _leaderboard.length,
                    itemBuilder: (context, index) =>
                        _buildLeaderboardRow(theme, _leaderboard[index]),
                  ),
          ),
        ],
      ),
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
          '${entry.points} points',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  void _navigateToApp(String appType) {
    final app = AppService().getAppByType(appType);
    if (app == null) return;
    final path = app.storagePath ?? '';

    final Widget? page;
    switch (appType) {
      case 'chat':
        page = ChatBrowserPage(app: app);
      case 'blog':
        page = BlogBrowserPage(appPath: path, appTitle: app.title);
      case 'places':
        page = PlacesBrowserPage(appPath: path, appTitle: app.title);
      case 'alerts':
        page = ReportBrowserPage(appPath: path, appTitle: app.title);
      case 'events':
        page = EventsBrowserPage(appPath: path, appTitle: app.title);
      default:
        page = null;
    }

    if (page != null) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => page!),
      );
    }
  }
}

