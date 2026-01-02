/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Currency information
class Currency {
  final String code;
  final String symbol;
  final String name;
  final Map<String, String> translations;

  const Currency({
    required this.code,
    required this.symbol,
    required this.name,
    required this.translations,
  });

  String getName(String langCode) {
    return translations[langCode] ?? name;
  }
}

/// List of currencies with main ones at the top
class Currencies {
  static const List<Currency> all = [
    // Main currencies at top
    Currency(
      code: 'EUR',
      symbol: '\u20AC',
      name: 'Euro',
      translations: {'EN': 'Euro', 'PT': 'Euro', 'ES': 'Euro', 'FR': 'Euro', 'DE': 'Euro'},
    ),
    Currency(
      code: 'USD',
      symbol: '\$',
      name: 'US Dollar',
      translations: {'EN': 'US Dollar', 'PT': 'Dolar Americano', 'ES': 'Dolar Estadounidense', 'FR': 'Dollar Americain', 'DE': 'US-Dollar'},
    ),
    Currency(
      code: 'GBP',
      symbol: '\u00A3',
      name: 'British Pound',
      translations: {'EN': 'British Pound', 'PT': 'Libra Esterlina', 'ES': 'Libra Esterlina', 'FR': 'Livre Sterling', 'DE': 'Britisches Pfund'},
    ),
    Currency(
      code: 'CHF',
      symbol: 'CHF',
      name: 'Swiss Franc',
      translations: {'EN': 'Swiss Franc', 'PT': 'Franco Suico', 'ES': 'Franco Suizo', 'FR': 'Franc Suisse', 'DE': 'Schweizer Franken'},
    ),
    Currency(
      code: 'JPY',
      symbol: '\u00A5',
      name: 'Japanese Yen',
      translations: {'EN': 'Japanese Yen', 'PT': 'Iene Japones', 'ES': 'Yen Japones', 'FR': 'Yen Japonais', 'DE': 'Japanischer Yen'},
    ),
    Currency(
      code: 'CNY',
      symbol: '\u00A5',
      name: 'Chinese Yuan',
      translations: {'EN': 'Chinese Yuan', 'PT': 'Yuan Chines', 'ES': 'Yuan Chino', 'FR': 'Yuan Chinois', 'DE': 'Chinesischer Yuan'},
    ),
    Currency(
      code: 'CAD',
      symbol: 'C\$',
      name: 'Canadian Dollar',
      translations: {'EN': 'Canadian Dollar', 'PT': 'Dolar Canadense', 'ES': 'Dolar Canadiense', 'FR': 'Dollar Canadien', 'DE': 'Kanadischer Dollar'},
    ),
    Currency(
      code: 'AUD',
      symbol: 'A\$',
      name: 'Australian Dollar',
      translations: {'EN': 'Australian Dollar', 'PT': 'Dolar Australiano', 'ES': 'Dolar Australiano', 'FR': 'Dollar Australien', 'DE': 'Australischer Dollar'},
    ),
    Currency(
      code: 'NZD',
      symbol: 'NZ\$',
      name: 'New Zealand Dollar',
      translations: {'EN': 'New Zealand Dollar', 'PT': 'Dolar Neozelandes', 'ES': 'Dolar Neozelandes', 'FR': 'Dollar Neo-Zelandais', 'DE': 'Neuseeland-Dollar'},
    ),
    Currency(
      code: 'SEK',
      symbol: 'kr',
      name: 'Swedish Krona',
      translations: {'EN': 'Swedish Krona', 'PT': 'Coroa Sueca', 'ES': 'Corona Sueca', 'FR': 'Couronne Suedoise', 'DE': 'Schwedische Krone'},
    ),
    Currency(
      code: 'NOK',
      symbol: 'kr',
      name: 'Norwegian Krone',
      translations: {'EN': 'Norwegian Krone', 'PT': 'Coroa Norueguesa', 'ES': 'Corona Noruega', 'FR': 'Couronne Norvegienne', 'DE': 'Norwegische Krone'},
    ),
    Currency(
      code: 'DKK',
      symbol: 'kr',
      name: 'Danish Krone',
      translations: {'EN': 'Danish Krone', 'PT': 'Coroa Dinamarquesa', 'ES': 'Corona Danesa', 'FR': 'Couronne Danoise', 'DE': 'Danische Krone'},
    ),
    Currency(
      code: 'PLN',
      symbol: 'zl',
      name: 'Polish Zloty',
      translations: {'EN': 'Polish Zloty', 'PT': 'Zloty Polones', 'ES': 'Zloty Polaco', 'FR': 'Zloty Polonais', 'DE': 'Polnischer Zloty'},
    ),
    Currency(
      code: 'CZK',
      symbol: 'Kc',
      name: 'Czech Koruna',
      translations: {'EN': 'Czech Koruna', 'PT': 'Coroa Checa', 'ES': 'Corona Checa', 'FR': 'Couronne Tcheque', 'DE': 'Tschechische Krone'},
    ),
    Currency(
      code: 'HUF',
      symbol: 'Ft',
      name: 'Hungarian Forint',
      translations: {'EN': 'Hungarian Forint', 'PT': 'Florim Hungaro', 'ES': 'Forint Hungaro', 'FR': 'Forint Hongrois', 'DE': 'Ungarischer Forint'},
    ),
    Currency(
      code: 'RON',
      symbol: 'lei',
      name: 'Romanian Leu',
      translations: {'EN': 'Romanian Leu', 'PT': 'Leu Romeno', 'ES': 'Leu Rumano', 'FR': 'Leu Roumain', 'DE': 'Rumanischer Leu'},
    ),
    Currency(
      code: 'BGN',
      symbol: 'лв',
      name: 'Bulgarian Lev',
      translations: {'EN': 'Bulgarian Lev', 'PT': 'Lev Bulgaro', 'ES': 'Lev Bulgaro', 'FR': 'Lev Bulgare', 'DE': 'Bulgarischer Lew'},
    ),
    Currency(
      code: 'RUB',
      symbol: '\u20BD',
      name: 'Russian Ruble',
      translations: {'EN': 'Russian Ruble', 'PT': 'Rublo Russo', 'ES': 'Rublo Ruso', 'FR': 'Rouble Russe', 'DE': 'Russischer Rubel'},
    ),
    Currency(
      code: 'INR',
      symbol: '\u20B9',
      name: 'Indian Rupee',
      translations: {'EN': 'Indian Rupee', 'PT': 'Rupia Indiana', 'ES': 'Rupia India', 'FR': 'Roupie Indienne', 'DE': 'Indische Rupie'},
    ),
    Currency(
      code: 'KRW',
      symbol: '\u20A9',
      name: 'South Korean Won',
      translations: {'EN': 'South Korean Won', 'PT': 'Won Sul-Coreano', 'ES': 'Won Surcoreano', 'FR': 'Won Sud-Coreen', 'DE': 'Sudkoreanischer Won'},
    ),
    Currency(
      code: 'SGD',
      symbol: 'S\$',
      name: 'Singapore Dollar',
      translations: {'EN': 'Singapore Dollar', 'PT': 'Dolar de Singapura', 'ES': 'Dolar de Singapur', 'FR': 'Dollar de Singapour', 'DE': 'Singapur-Dollar'},
    ),
    Currency(
      code: 'HKD',
      symbol: 'HK\$',
      name: 'Hong Kong Dollar',
      translations: {'EN': 'Hong Kong Dollar', 'PT': 'Dolar de Hong Kong', 'ES': 'Dolar de Hong Kong', 'FR': 'Dollar de Hong Kong', 'DE': 'Hongkong-Dollar'},
    ),
    Currency(
      code: 'MXN',
      symbol: 'Mex\$',
      name: 'Mexican Peso',
      translations: {'EN': 'Mexican Peso', 'PT': 'Peso Mexicano', 'ES': 'Peso Mexicano', 'FR': 'Peso Mexicain', 'DE': 'Mexikanischer Peso'},
    ),
    Currency(
      code: 'BRL',
      symbol: 'R\$',
      name: 'Brazilian Real',
      translations: {'EN': 'Brazilian Real', 'PT': 'Real Brasileiro', 'ES': 'Real Brasileno', 'FR': 'Real Bresilien', 'DE': 'Brasilianischer Real'},
    ),
    Currency(
      code: 'ARS',
      symbol: '\$',
      name: 'Argentine Peso',
      translations: {'EN': 'Argentine Peso', 'PT': 'Peso Argentino', 'ES': 'Peso Argentino', 'FR': 'Peso Argentin', 'DE': 'Argentinischer Peso'},
    ),
    Currency(
      code: 'CLP',
      symbol: '\$',
      name: 'Chilean Peso',
      translations: {'EN': 'Chilean Peso', 'PT': 'Peso Chileno', 'ES': 'Peso Chileno', 'FR': 'Peso Chilien', 'DE': 'Chilenischer Peso'},
    ),
    Currency(
      code: 'COP',
      symbol: '\$',
      name: 'Colombian Peso',
      translations: {'EN': 'Colombian Peso', 'PT': 'Peso Colombiano', 'ES': 'Peso Colombiano', 'FR': 'Peso Colombien', 'DE': 'Kolumbianischer Peso'},
    ),
    Currency(
      code: 'ZAR',
      symbol: 'R',
      name: 'South African Rand',
      translations: {'EN': 'South African Rand', 'PT': 'Rand Sul-Africano', 'ES': 'Rand Sudafricano', 'FR': 'Rand Sud-Africain', 'DE': 'Sudafrikanischer Rand'},
    ),
    Currency(
      code: 'TRY',
      symbol: '\u20BA',
      name: 'Turkish Lira',
      translations: {'EN': 'Turkish Lira', 'PT': 'Lira Turca', 'ES': 'Lira Turca', 'FR': 'Livre Turque', 'DE': 'Turkische Lira'},
    ),
    Currency(
      code: 'ILS',
      symbol: '\u20AA',
      name: 'Israeli Shekel',
      translations: {'EN': 'Israeli Shekel', 'PT': 'Shekel Israelita', 'ES': 'Shekel Israeli', 'FR': 'Shekel Israelien', 'DE': 'Israelischer Schekel'},
    ),
    Currency(
      code: 'AED',
      symbol: 'د.إ',
      name: 'UAE Dirham',
      translations: {'EN': 'UAE Dirham', 'PT': 'Dirham dos EAU', 'ES': 'Dirham de EAU', 'FR': 'Dirham des EAU', 'DE': 'VAE-Dirham'},
    ),
    Currency(
      code: 'SAR',
      symbol: '\uFDFC',
      name: 'Saudi Riyal',
      translations: {'EN': 'Saudi Riyal', 'PT': 'Rial Saudita', 'ES': 'Riyal Saudi', 'FR': 'Riyal Saoudien', 'DE': 'Saudi-Rial'},
    ),
    Currency(
      code: 'THB',
      symbol: '\u0E3F',
      name: 'Thai Baht',
      translations: {'EN': 'Thai Baht', 'PT': 'Baht Tailandes', 'ES': 'Baht Tailandes', 'FR': 'Baht Thailandais', 'DE': 'Thailandischer Baht'},
    ),
    Currency(
      code: 'MYR',
      symbol: 'RM',
      name: 'Malaysian Ringgit',
      translations: {'EN': 'Malaysian Ringgit', 'PT': 'Ringgit Malaio', 'ES': 'Ringgit Malayo', 'FR': 'Ringgit Malaisien', 'DE': 'Malaysischer Ringgit'},
    ),
    Currency(
      code: 'IDR',
      symbol: 'Rp',
      name: 'Indonesian Rupiah',
      translations: {'EN': 'Indonesian Rupiah', 'PT': 'Rupia Indonesa', 'ES': 'Rupia Indonesia', 'FR': 'Roupie Indonesienne', 'DE': 'Indonesische Rupiah'},
    ),
    Currency(
      code: 'PHP',
      symbol: '\u20B1',
      name: 'Philippine Peso',
      translations: {'EN': 'Philippine Peso', 'PT': 'Peso Filipino', 'ES': 'Peso Filipino', 'FR': 'Peso Philippin', 'DE': 'Philippinischer Peso'},
    ),
    Currency(
      code: 'VND',
      symbol: '\u20AB',
      name: 'Vietnamese Dong',
      translations: {'EN': 'Vietnamese Dong', 'PT': 'Dong Vietnamita', 'ES': 'Dong Vietnamita', 'FR': 'Dong Vietnamien', 'DE': 'Vietnamesischer Dong'},
    ),
    Currency(
      code: 'TWD',
      symbol: 'NT\$',
      name: 'Taiwan Dollar',
      translations: {'EN': 'Taiwan Dollar', 'PT': 'Dolar de Taiwan', 'ES': 'Dolar de Taiwan', 'FR': 'Dollar de Taiwan', 'DE': 'Taiwan-Dollar'},
    ),
  ];

  /// Get currency by code
  static Currency? getByCode(String code) {
    try {
      return all.firstWhere((c) => c.code == code);
    } catch (_) {
      return null;
    }
  }

  /// Format a value with currency symbol
  static String format(double value, String currencyCode) {
    final currency = getByCode(currencyCode);
    if (currency == null) {
      return '$value $currencyCode';
    }
    // Format with 2 decimal places
    final formatted = value.toStringAsFixed(2);
    return '${currency.symbol}$formatted';
  }
}
