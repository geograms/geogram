/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/reader_models.dart';
import '../services/manga_service.dart';
import '../services/reader_service.dart';
import '../../services/i18n_service.dart';

/// Page for reading manga chapters
class MangaReaderPage extends StatefulWidget {
  final String appPath;
  final String sourceId;
  final String mangaSlug;
  final MangaChapter chapter;
  final String chapterPath;
  final I18nService i18n;

  const MangaReaderPage({
    super.key,
    required this.appPath,
    required this.sourceId,
    required this.mangaSlug,
    required this.chapter,
    required this.chapterPath,
    required this.i18n,
  });

  @override
  State<MangaReaderPage> createState() => _MangaReaderPageState();
}

class _MangaReaderPageState extends State<MangaReaderPage> {
  final ReaderService _readerService = ReaderService();
  final MangaService _mangaService = MangaService();

  List<MangaPage> _pages = [];
  int _currentPage = 0;
  bool _loading = true;
  bool _showControls = true;
  bool _isWebtoonMode = true;

  final PageController _pageController = PageController();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadPages();
    // Hide system UI for immersive reading
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _scrollController.dispose();
    // Restore system UI
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _loadPages() async {
    try {
      final pages = await _mangaService.extractPages(widget.chapterPath);

      // Load saved progress
      final progress =
          _readerService.getMangaProgress(widget.sourceId, widget.mangaSlug);
      int startPage = 0;
      if (progress != null && progress.currentChapter == widget.chapter.filename) {
        startPage = progress.currentPage;
      }

      if (mounted) {
        setState(() {
          _pages = pages;
          _currentPage = startPage;
          _loading = false;
        });

        // Jump to saved page
        if (startPage > 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_isWebtoonMode) {
              // Scroll to approximate position
            } else {
              _pageController.jumpToPage(startPage);
            }
          });
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading pages: $e')),
        );
        Navigator.pop(context);
      }
    }
  }

  void _onPageChanged(int page) {
    setState(() => _currentPage = page);
    _saveProgress(page);
  }

  void _saveProgress(int page) {
    _readerService.updateMangaProgress(
      widget.sourceId,
      widget.mangaSlug,
      widget.chapter.filename,
      page,
    );

    // Mark chapter as read if on last page
    if (page >= _pages.length - 1) {
      _readerService.markChapterRead(
        widget.sourceId,
        widget.mangaSlug,
        widget.chapter.filename,
      );
    }
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
  }

  void _goToPage(int page) {
    if (page < 0 || page >= _pages.length) return;

    if (_isWebtoonMode) {
      // Scroll mode - not implemented
    } else {
      _pageController.animateToPage(
        page,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _nextPage() {
    _goToPage(_currentPage + 1);
  }

  void _previousPage() {
    _goToPage(_currentPage - 1);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Main content
          GestureDetector(
            onTap: _toggleControls,
            onHorizontalDragEnd: (details) {
              if (details.primaryVelocity == null) return;
              if (details.primaryVelocity! < 0) {
                _nextPage();
              } else if (details.primaryVelocity! > 0) {
                _previousPage();
              }
            },
            child: _isWebtoonMode
                ? _buildWebtoonView()
                : _buildPageView(),
          ),

          // Controls overlay
          if (_showControls) ...[
            // Top bar
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black87,
                      Colors.transparent,
                    ],
                  ),
                ),
                child: SafeArea(
                  child: AppBar(
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                    title: Text(widget.chapter.displayName),
                    actions: [
                      IconButton(
                        icon: Icon(_isWebtoonMode
                            ? Icons.view_carousel
                            : Icons.view_day),
                        onPressed: () =>
                            setState(() => _isWebtoonMode = !_isWebtoonMode),
                        tooltip:
                            _isWebtoonMode ? 'Page mode' : 'Webtoon mode',
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Bottom bar
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black87,
                      Colors.transparent,
                    ],
                  ),
                ),
                child: SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Page slider
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Text(
                              '${_currentPage + 1}',
                              style: const TextStyle(color: Colors.white),
                            ),
                            Expanded(
                              child: Slider(
                                value: _currentPage.toDouble(),
                                min: 0,
                                max: (_pages.length - 1).toDouble(),
                                onChanged: (value) {
                                  _goToPage(value.round());
                                },
                              ),
                            ),
                            Text(
                              '${_pages.length}',
                              style: const TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      ),

                      // Navigation buttons
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.skip_previous,
                                color: Colors.white),
                            onPressed: _currentPage > 0
                                ? () => _goToPage(0)
                                : null,
                          ),
                          IconButton(
                            icon: const Icon(Icons.chevron_left,
                                color: Colors.white, size: 36),
                            onPressed: _currentPage > 0 ? _previousPage : null,
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.white24,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              '${_currentPage + 1} / ${_pages.length}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.chevron_right,
                                color: Colors.white, size: 36),
                            onPressed:
                                _currentPage < _pages.length - 1 ? _nextPage : null,
                          ),
                          IconButton(
                            icon: const Icon(Icons.skip_next,
                                color: Colors.white),
                            onPressed: _currentPage < _pages.length - 1
                                ? () => _goToPage(_pages.length - 1)
                                : null,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPageView() {
    return PageView.builder(
      controller: _pageController,
      itemCount: _pages.length,
      onPageChanged: _onPageChanged,
      itemBuilder: (context, index) {
        return InteractiveViewer(
          minScale: 1.0,
          maxScale: 4.0,
          child: Center(
            child: Image.memory(
              _pages[index].data,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) {
                return const Center(child: Icon(Icons.broken_image, size: 48, color: Colors.grey));
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildWebtoonView() {
    return ListView.builder(
      controller: _scrollController,
      itemCount: _pages.length,
      itemBuilder: (context, index) {
        return Image.memory(
          _pages[index].data,
          fit: BoxFit.fitWidth,
          errorBuilder: (context, error, stackTrace) {
            return const SizedBox(
              height: 200,
              child: Center(child: Icon(Icons.broken_image, size: 48, color: Colors.grey)),
            );
          },
        );
      },
    );
  }
}
