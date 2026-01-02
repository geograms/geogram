/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Category of measurement unit
enum UnitCategory {
  volume,
  weight,
  length,
  area,
  count,
  time,
  digital,
  temperature,
  other,
}

/// Represents a measurement unit
class MeasurementUnit {
  final String id;
  final String symbol;
  final UnitCategory category;
  final Map<String, String> translations;
  final double? conversionFactor; // Factor to convert to base unit
  final String? baseUnit; // ID of base unit for conversion

  const MeasurementUnit({
    required this.id,
    required this.symbol,
    required this.category,
    this.translations = const {},
    this.conversionFactor,
    this.baseUnit,
  });

  /// Get localized name
  String getName(String langCode) {
    return translations[langCode] ?? id;
  }

  /// Format a quantity with this unit
  String format(double quantity, {int decimals = 1}) {
    final formatted = quantity.toStringAsFixed(decimals);
    return '$formatted $symbol';
  }
}

/// Catalog of all measurement units
class MeasurementUnits {
  MeasurementUnits._();

  // Volume units
  static const liters = MeasurementUnit(
    id: 'liters',
    symbol: 'L',
    category: UnitCategory.volume,
    translations: {
      'EN': 'Liters',
      'PT': 'Litros',
      'ES': 'Litros',
      'FR': 'Litres',
      'DE': 'Liter',
      'IT': 'Litri',
      'NL': 'Liters',
      'PL': 'Litry',
      'RU': 'Литры',
      'ZH': '升',
      'JA': 'リットル',
    },
    conversionFactor: 1,
    baseUnit: 'liters',
  );

  static const milliliters = MeasurementUnit(
    id: 'milliliters',
    symbol: 'mL',
    category: UnitCategory.volume,
    translations: {
      'EN': 'Milliliters',
      'PT': 'Mililitros',
      'ES': 'Mililitros',
      'FR': 'Millilitres',
      'DE': 'Milliliter',
      'IT': 'Millilitri',
      'NL': 'Milliliters',
      'PL': 'Mililitry',
      'RU': 'Миллилитры',
      'ZH': '毫升',
      'JA': 'ミリリットル',
    },
    conversionFactor: 0.001,
    baseUnit: 'liters',
  );

  static const gallons = MeasurementUnit(
    id: 'gallons',
    symbol: 'gal',
    category: UnitCategory.volume,
    translations: {
      'EN': 'Gallons',
      'PT': 'Galões',
      'ES': 'Galones',
      'FR': 'Gallons',
      'DE': 'Gallonen',
      'IT': 'Galloni',
      'NL': 'Gallons',
      'PL': 'Galony',
      'RU': 'Галлоны',
      'ZH': '加仑',
      'JA': 'ガロン',
    },
    conversionFactor: 3.78541,
    baseUnit: 'liters',
  );

  static const cubicMeters = MeasurementUnit(
    id: 'cubic_meters',
    symbol: 'm³',
    category: UnitCategory.volume,
    translations: {
      'EN': 'Cubic Meters',
      'PT': 'Metros Cúbicos',
      'ES': 'Metros Cúbicos',
      'FR': 'Mètres Cubes',
      'DE': 'Kubikmeter',
      'IT': 'Metri Cubi',
      'NL': 'Kubieke Meters',
      'PL': 'Metry Sześcienne',
      'RU': 'Кубические метры',
      'ZH': '立方米',
      'JA': '立方メートル',
    },
    conversionFactor: 1000,
    baseUnit: 'liters',
  );

  // Weight units
  static const kilograms = MeasurementUnit(
    id: 'kilograms',
    symbol: 'kg',
    category: UnitCategory.weight,
    translations: {
      'EN': 'Kilograms',
      'PT': 'Quilogramas',
      'ES': 'Kilogramos',
      'FR': 'Kilogrammes',
      'DE': 'Kilogramm',
      'IT': 'Chilogrammi',
      'NL': 'Kilogrammen',
      'PL': 'Kilogramy',
      'RU': 'Килограммы',
      'ZH': '公斤',
      'JA': 'キログラム',
    },
    conversionFactor: 1,
    baseUnit: 'kilograms',
  );

  static const grams = MeasurementUnit(
    id: 'grams',
    symbol: 'g',
    category: UnitCategory.weight,
    translations: {
      'EN': 'Grams',
      'PT': 'Gramas',
      'ES': 'Gramos',
      'FR': 'Grammes',
      'DE': 'Gramm',
      'IT': 'Grammi',
      'NL': 'Gram',
      'PL': 'Gramy',
      'RU': 'Граммы',
      'ZH': '克',
      'JA': 'グラム',
    },
    conversionFactor: 0.001,
    baseUnit: 'kilograms',
  );

  static const milligrams = MeasurementUnit(
    id: 'milligrams',
    symbol: 'mg',
    category: UnitCategory.weight,
    translations: {
      'EN': 'Milligrams',
      'PT': 'Miligramas',
      'ES': 'Miligramos',
      'FR': 'Milligrammes',
      'DE': 'Milligramm',
      'IT': 'Milligrammi',
      'NL': 'Milligram',
      'PL': 'Miligramy',
      'RU': 'Миллиграммы',
      'ZH': '毫克',
      'JA': 'ミリグラム',
    },
    conversionFactor: 0.000001,
    baseUnit: 'kilograms',
  );

  static const pounds = MeasurementUnit(
    id: 'pounds',
    symbol: 'lb',
    category: UnitCategory.weight,
    translations: {
      'EN': 'Pounds',
      'PT': 'Libras',
      'ES': 'Libras',
      'FR': 'Livres',
      'DE': 'Pfund',
      'IT': 'Libbre',
      'NL': 'Ponden',
      'PL': 'Funty',
      'RU': 'Фунты',
      'ZH': '磅',
      'JA': 'ポンド',
    },
    conversionFactor: 0.453592,
    baseUnit: 'kilograms',
  );

  static const ounces = MeasurementUnit(
    id: 'ounces',
    symbol: 'oz',
    category: UnitCategory.weight,
    translations: {
      'EN': 'Ounces',
      'PT': 'Onças',
      'ES': 'Onzas',
      'FR': 'Onces',
      'DE': 'Unzen',
      'IT': 'Once',
      'NL': 'Ons',
      'PL': 'Uncje',
      'RU': 'Унции',
      'ZH': '盎司',
      'JA': 'オンス',
    },
    conversionFactor: 0.0283495,
    baseUnit: 'kilograms',
  );

  static const tons = MeasurementUnit(
    id: 'tons',
    symbol: 't',
    category: UnitCategory.weight,
    translations: {
      'EN': 'Tons',
      'PT': 'Toneladas',
      'ES': 'Toneladas',
      'FR': 'Tonnes',
      'DE': 'Tonnen',
      'IT': 'Tonnellate',
      'NL': 'Ton',
      'PL': 'Tony',
      'RU': 'Тонны',
      'ZH': '吨',
      'JA': 'トン',
    },
    conversionFactor: 1000,
    baseUnit: 'kilograms',
  );

  // Length units
  static const meters = MeasurementUnit(
    id: 'meters',
    symbol: 'm',
    category: UnitCategory.length,
    translations: {
      'EN': 'Meters',
      'PT': 'Metros',
      'ES': 'Metros',
      'FR': 'Mètres',
      'DE': 'Meter',
      'IT': 'Metri',
      'NL': 'Meters',
      'PL': 'Metry',
      'RU': 'Метры',
      'ZH': '米',
      'JA': 'メートル',
    },
    conversionFactor: 1,
    baseUnit: 'meters',
  );

  static const centimeters = MeasurementUnit(
    id: 'centimeters',
    symbol: 'cm',
    category: UnitCategory.length,
    translations: {
      'EN': 'Centimeters',
      'PT': 'Centímetros',
      'ES': 'Centímetros',
      'FR': 'Centimètres',
      'DE': 'Zentimeter',
      'IT': 'Centimetri',
      'NL': 'Centimeters',
      'PL': 'Centymetry',
      'RU': 'Сантиметры',
      'ZH': '厘米',
      'JA': 'センチメートル',
    },
    conversionFactor: 0.01,
    baseUnit: 'meters',
  );

  static const millimeters = MeasurementUnit(
    id: 'millimeters',
    symbol: 'mm',
    category: UnitCategory.length,
    translations: {
      'EN': 'Millimeters',
      'PT': 'Milímetros',
      'ES': 'Milímetros',
      'FR': 'Millimètres',
      'DE': 'Millimeter',
      'IT': 'Millimetri',
      'NL': 'Millimeters',
      'PL': 'Milimetry',
      'RU': 'Миллиметры',
      'ZH': '毫米',
      'JA': 'ミリメートル',
    },
    conversionFactor: 0.001,
    baseUnit: 'meters',
  );

  static const kilometers = MeasurementUnit(
    id: 'kilometers',
    symbol: 'km',
    category: UnitCategory.length,
    translations: {
      'EN': 'Kilometers',
      'PT': 'Quilômetros',
      'ES': 'Kilómetros',
      'FR': 'Kilomètres',
      'DE': 'Kilometer',
      'IT': 'Chilometri',
      'NL': 'Kilometers',
      'PL': 'Kilometry',
      'RU': 'Километры',
      'ZH': '公里',
      'JA': 'キロメートル',
    },
    conversionFactor: 1000,
    baseUnit: 'meters',
  );

  static const inches = MeasurementUnit(
    id: 'inches',
    symbol: 'in',
    category: UnitCategory.length,
    translations: {
      'EN': 'Inches',
      'PT': 'Polegadas',
      'ES': 'Pulgadas',
      'FR': 'Pouces',
      'DE': 'Zoll',
      'IT': 'Pollici',
      'NL': 'Inch',
      'PL': 'Cale',
      'RU': 'Дюймы',
      'ZH': '英寸',
      'JA': 'インチ',
    },
    conversionFactor: 0.0254,
    baseUnit: 'meters',
  );

  static const feet = MeasurementUnit(
    id: 'feet',
    symbol: 'ft',
    category: UnitCategory.length,
    translations: {
      'EN': 'Feet',
      'PT': 'Pés',
      'ES': 'Pies',
      'FR': 'Pieds',
      'DE': 'Fuß',
      'IT': 'Piedi',
      'NL': 'Voet',
      'PL': 'Stopy',
      'RU': 'Футы',
      'ZH': '英尺',
      'JA': 'フィート',
    },
    conversionFactor: 0.3048,
    baseUnit: 'meters',
  );

  static const yards = MeasurementUnit(
    id: 'yards',
    symbol: 'yd',
    category: UnitCategory.length,
    translations: {
      'EN': 'Yards',
      'PT': 'Jardas',
      'ES': 'Yardas',
      'FR': 'Yards',
      'DE': 'Yards',
      'IT': 'Iarde',
      'NL': 'Yards',
      'PL': 'Jardy',
      'RU': 'Ярды',
      'ZH': '码',
      'JA': 'ヤード',
    },
    conversionFactor: 0.9144,
    baseUnit: 'meters',
  );

  static const miles = MeasurementUnit(
    id: 'miles',
    symbol: 'mi',
    category: UnitCategory.length,
    translations: {
      'EN': 'Miles',
      'PT': 'Milhas',
      'ES': 'Millas',
      'FR': 'Miles',
      'DE': 'Meilen',
      'IT': 'Miglia',
      'NL': 'Mijlen',
      'PL': 'Mile',
      'RU': 'Мили',
      'ZH': '英里',
      'JA': 'マイル',
    },
    conversionFactor: 1609.34,
    baseUnit: 'meters',
  );

  // Area units
  static const squareMeters = MeasurementUnit(
    id: 'square_meters',
    symbol: 'm²',
    category: UnitCategory.area,
    translations: {
      'EN': 'Square Meters',
      'PT': 'Metros Quadrados',
      'ES': 'Metros Cuadrados',
      'FR': 'Mètres Carrés',
      'DE': 'Quadratmeter',
      'IT': 'Metri Quadrati',
      'NL': 'Vierkante Meters',
      'PL': 'Metry Kwadratowe',
      'RU': 'Квадратные метры',
      'ZH': '平方米',
      'JA': '平方メートル',
    },
    conversionFactor: 1,
    baseUnit: 'square_meters',
  );

  static const hectares = MeasurementUnit(
    id: 'hectares',
    symbol: 'ha',
    category: UnitCategory.area,
    translations: {
      'EN': 'Hectares',
      'PT': 'Hectares',
      'ES': 'Hectáreas',
      'FR': 'Hectares',
      'DE': 'Hektar',
      'IT': 'Ettari',
      'NL': 'Hectaren',
      'PL': 'Hektary',
      'RU': 'Гектары',
      'ZH': '公顷',
      'JA': 'ヘクタール',
    },
    conversionFactor: 10000,
    baseUnit: 'square_meters',
  );

  static const acres = MeasurementUnit(
    id: 'acres',
    symbol: 'ac',
    category: UnitCategory.area,
    translations: {
      'EN': 'Acres',
      'PT': 'Acres',
      'ES': 'Acres',
      'FR': 'Acres',
      'DE': 'Acres',
      'IT': 'Acri',
      'NL': 'Acres',
      'PL': 'Akry',
      'RU': 'Акры',
      'ZH': '英亩',
      'JA': 'エーカー',
    },
    conversionFactor: 4046.86,
    baseUnit: 'square_meters',
  );

  // Count units
  static const units = MeasurementUnit(
    id: 'units',
    symbol: 'u',
    category: UnitCategory.count,
    translations: {
      'EN': 'Units',
      'PT': 'Unidades',
      'ES': 'Unidades',
      'FR': 'Unités',
      'DE': 'Einheiten',
      'IT': 'Unità',
      'NL': 'Eenheden',
      'PL': 'Jednostki',
      'RU': 'Единицы',
      'ZH': '单位',
      'JA': '個',
    },
  );

  static const pieces = MeasurementUnit(
    id: 'pieces',
    symbol: 'pcs',
    category: UnitCategory.count,
    translations: {
      'EN': 'Pieces',
      'PT': 'Peças',
      'ES': 'Piezas',
      'FR': 'Pièces',
      'DE': 'Stück',
      'IT': 'Pezzi',
      'NL': 'Stuks',
      'PL': 'Sztuki',
      'RU': 'Штуки',
      'ZH': '件',
      'JA': '個',
    },
  );

  static const pairs = MeasurementUnit(
    id: 'pairs',
    symbol: 'pr',
    category: UnitCategory.count,
    translations: {
      'EN': 'Pairs',
      'PT': 'Pares',
      'ES': 'Pares',
      'FR': 'Paires',
      'DE': 'Paare',
      'IT': 'Paia',
      'NL': 'Paren',
      'PL': 'Pary',
      'RU': 'Пары',
      'ZH': '双',
      'JA': '組',
    },
  );

  static const dozen = MeasurementUnit(
    id: 'dozen',
    symbol: 'dz',
    category: UnitCategory.count,
    translations: {
      'EN': 'Dozen',
      'PT': 'Dúzias',
      'ES': 'Docenas',
      'FR': 'Douzaines',
      'DE': 'Dutzend',
      'IT': 'Dozzine',
      'NL': 'Dozijn',
      'PL': 'Tuziny',
      'RU': 'Дюжины',
      'ZH': '打',
      'JA': 'ダース',
    },
  );

  static const boxes = MeasurementUnit(
    id: 'boxes',
    symbol: 'box',
    category: UnitCategory.count,
    translations: {
      'EN': 'Boxes',
      'PT': 'Caixas',
      'ES': 'Cajas',
      'FR': 'Boîtes',
      'DE': 'Boxen',
      'IT': 'Scatole',
      'NL': 'Dozen',
      'PL': 'Pudełka',
      'RU': 'Коробки',
      'ZH': '盒',
      'JA': '箱',
    },
  );

  static const packs = MeasurementUnit(
    id: 'packs',
    symbol: 'pk',
    category: UnitCategory.count,
    translations: {
      'EN': 'Packs',
      'PT': 'Pacotes',
      'ES': 'Paquetes',
      'FR': 'Paquets',
      'DE': 'Packungen',
      'IT': 'Pacchi',
      'NL': 'Pakken',
      'PL': 'Opakowania',
      'RU': 'Пачки',
      'ZH': '包',
      'JA': 'パック',
    },
  );

  static const rolls = MeasurementUnit(
    id: 'rolls',
    symbol: 'roll',
    category: UnitCategory.count,
    translations: {
      'EN': 'Rolls',
      'PT': 'Rolos',
      'ES': 'Rollos',
      'FR': 'Rouleaux',
      'DE': 'Rollen',
      'IT': 'Rotoli',
      'NL': 'Rollen',
      'PL': 'Rolki',
      'RU': 'Рулоны',
      'ZH': '卷',
      'JA': 'ロール',
    },
  );

  static const sheets = MeasurementUnit(
    id: 'sheets',
    symbol: 'sht',
    category: UnitCategory.count,
    translations: {
      'EN': 'Sheets',
      'PT': 'Folhas',
      'ES': 'Hojas',
      'FR': 'Feuilles',
      'DE': 'Blätter',
      'IT': 'Fogli',
      'NL': 'Vellen',
      'PL': 'Arkusze',
      'RU': 'Листы',
      'ZH': '张',
      'JA': '枚',
    },
  );

  static const bottles = MeasurementUnit(
    id: 'bottles',
    symbol: 'btl',
    category: UnitCategory.count,
    translations: {
      'EN': 'Bottles',
      'PT': 'Garrafas',
      'ES': 'Botellas',
      'FR': 'Bouteilles',
      'DE': 'Flaschen',
      'IT': 'Bottiglie',
      'NL': 'Flessen',
      'PL': 'Butelki',
      'RU': 'Бутылки',
      'ZH': '瓶',
      'JA': '本',
    },
  );

  static const cans = MeasurementUnit(
    id: 'cans',
    symbol: 'can',
    category: UnitCategory.count,
    translations: {
      'EN': 'Cans',
      'PT': 'Latas',
      'ES': 'Latas',
      'FR': 'Canettes',
      'DE': 'Dosen',
      'IT': 'Lattine',
      'NL': 'Blikken',
      'PL': 'Puszki',
      'RU': 'Банки',
      'ZH': '罐',
      'JA': '缶',
    },
  );

  static const bags = MeasurementUnit(
    id: 'bags',
    symbol: 'bag',
    category: UnitCategory.count,
    translations: {
      'EN': 'Bags',
      'PT': 'Sacos',
      'ES': 'Bolsas',
      'FR': 'Sacs',
      'DE': 'Taschen',
      'IT': 'Sacchi',
      'NL': 'Zakken',
      'PL': 'Torby',
      'RU': 'Мешки',
      'ZH': '袋',
      'JA': '袋',
    },
  );

  // Digital units
  static const bytes = MeasurementUnit(
    id: 'bytes',
    symbol: 'B',
    category: UnitCategory.digital,
    translations: {
      'EN': 'Bytes',
      'PT': 'Bytes',
      'ES': 'Bytes',
      'FR': 'Octets',
      'DE': 'Bytes',
      'IT': 'Byte',
      'NL': 'Bytes',
      'PL': 'Bajty',
      'RU': 'Байты',
      'ZH': '字节',
      'JA': 'バイト',
    },
    conversionFactor: 1,
    baseUnit: 'bytes',
  );

  static const kilobytes = MeasurementUnit(
    id: 'kilobytes',
    symbol: 'KB',
    category: UnitCategory.digital,
    translations: {
      'EN': 'Kilobytes',
      'PT': 'Kilobytes',
      'ES': 'Kilobytes',
      'FR': 'Kilooctets',
      'DE': 'Kilobytes',
      'IT': 'Kilobyte',
      'NL': 'Kilobytes',
      'PL': 'Kilobajty',
      'RU': 'Килобайты',
      'ZH': '千字节',
      'JA': 'キロバイト',
    },
    conversionFactor: 1024,
    baseUnit: 'bytes',
  );

  static const megabytes = MeasurementUnit(
    id: 'megabytes',
    symbol: 'MB',
    category: UnitCategory.digital,
    translations: {
      'EN': 'Megabytes',
      'PT': 'Megabytes',
      'ES': 'Megabytes',
      'FR': 'Mégaoctets',
      'DE': 'Megabytes',
      'IT': 'Megabyte',
      'NL': 'Megabytes',
      'PL': 'Megabajty',
      'RU': 'Мегабайты',
      'ZH': '兆字节',
      'JA': 'メガバイト',
    },
    conversionFactor: 1048576,
    baseUnit: 'bytes',
  );

  static const gigabytes = MeasurementUnit(
    id: 'gigabytes',
    symbol: 'GB',
    category: UnitCategory.digital,
    translations: {
      'EN': 'Gigabytes',
      'PT': 'Gigabytes',
      'ES': 'Gigabytes',
      'FR': 'Gigaoctets',
      'DE': 'Gigabytes',
      'IT': 'Gigabyte',
      'NL': 'Gigabytes',
      'PL': 'Gigabajty',
      'RU': 'Гигабайты',
      'ZH': '吉字节',
      'JA': 'ギガバイト',
    },
    conversionFactor: 1073741824,
    baseUnit: 'bytes',
  );

  static const terabytes = MeasurementUnit(
    id: 'terabytes',
    symbol: 'TB',
    category: UnitCategory.digital,
    translations: {
      'EN': 'Terabytes',
      'PT': 'Terabytes',
      'ES': 'Terabytes',
      'FR': 'Téraoctets',
      'DE': 'Terabytes',
      'IT': 'Terabyte',
      'NL': 'Terabytes',
      'PL': 'Terabajty',
      'RU': 'Терабайты',
      'ZH': '太字节',
      'JA': 'テラバイト',
    },
    conversionFactor: 1099511627776,
    baseUnit: 'bytes',
  );

  // Time units
  static const seconds = MeasurementUnit(
    id: 'seconds',
    symbol: 's',
    category: UnitCategory.time,
    translations: {
      'EN': 'Seconds',
      'PT': 'Segundos',
      'ES': 'Segundos',
      'FR': 'Secondes',
      'DE': 'Sekunden',
      'IT': 'Secondi',
      'NL': 'Seconden',
      'PL': 'Sekundy',
      'RU': 'Секунды',
      'ZH': '秒',
      'JA': '秒',
    },
    conversionFactor: 1,
    baseUnit: 'seconds',
  );

  static const minutes = MeasurementUnit(
    id: 'minutes',
    symbol: 'min',
    category: UnitCategory.time,
    translations: {
      'EN': 'Minutes',
      'PT': 'Minutos',
      'ES': 'Minutos',
      'FR': 'Minutes',
      'DE': 'Minuten',
      'IT': 'Minuti',
      'NL': 'Minuten',
      'PL': 'Minuty',
      'RU': 'Минуты',
      'ZH': '分钟',
      'JA': '分',
    },
    conversionFactor: 60,
    baseUnit: 'seconds',
  );

  static const hours = MeasurementUnit(
    id: 'hours',
    symbol: 'h',
    category: UnitCategory.time,
    translations: {
      'EN': 'Hours',
      'PT': 'Horas',
      'ES': 'Horas',
      'FR': 'Heures',
      'DE': 'Stunden',
      'IT': 'Ore',
      'NL': 'Uren',
      'PL': 'Godziny',
      'RU': 'Часы',
      'ZH': '小时',
      'JA': '時間',
    },
    conversionFactor: 3600,
    baseUnit: 'seconds',
  );

  static const days = MeasurementUnit(
    id: 'days',
    symbol: 'd',
    category: UnitCategory.time,
    translations: {
      'EN': 'Days',
      'PT': 'Dias',
      'ES': 'Días',
      'FR': 'Jours',
      'DE': 'Tage',
      'IT': 'Giorni',
      'NL': 'Dagen',
      'PL': 'Dni',
      'RU': 'Дни',
      'ZH': '天',
      'JA': '日',
    },
    conversionFactor: 86400,
    baseUnit: 'seconds',
  );

  /// All available units
  static const List<MeasurementUnit> all = [
    // Volume
    liters,
    milliliters,
    gallons,
    cubicMeters,
    // Weight
    kilograms,
    grams,
    milligrams,
    pounds,
    ounces,
    tons,
    // Length
    meters,
    centimeters,
    millimeters,
    kilometers,
    inches,
    feet,
    yards,
    miles,
    // Area
    squareMeters,
    hectares,
    acres,
    // Count
    units,
    pieces,
    pairs,
    dozen,
    boxes,
    packs,
    rolls,
    sheets,
    bottles,
    cans,
    bags,
    // Digital
    bytes,
    kilobytes,
    megabytes,
    gigabytes,
    terabytes,
    // Time
    seconds,
    minutes,
    hours,
    days,
  ];

  /// Get units by category
  static List<MeasurementUnit> byCategory(UnitCategory category) {
    return all.where((u) => u.category == category).toList();
  }

  /// Get a unit by ID
  static MeasurementUnit? getById(String id) {
    try {
      return all.firstWhere((u) => u.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Search units by name or symbol
  static List<MeasurementUnit> search(String query, {String langCode = 'EN'}) {
    final q = query.toLowerCase();
    return all.where((u) {
      return u.id.toLowerCase().contains(q) ||
          u.symbol.toLowerCase().contains(q) ||
          u.getName(langCode).toLowerCase().contains(q);
    }).toList();
  }

  /// Convert between units of the same category
  static double? convert(
    double value,
    MeasurementUnit from,
    MeasurementUnit to,
  ) {
    if (from.category != to.category) return null;
    if (from.baseUnit == null || to.baseUnit == null) return null;
    if (from.conversionFactor == null || to.conversionFactor == null) {
      return null;
    }

    // Convert to base unit, then to target unit
    final baseValue = value * from.conversionFactor!;
    return baseValue / to.conversionFactor!;
  }
}
