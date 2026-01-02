/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Category for item types
enum ItemCategory {
  food,
  beverages,
  household,
  electronics,
  tools,
  outdoor,
  automotive,
  office,
  medical,
  clothing,
  sports,
  garden,
  pets,
  crafts,
  music,
  photography,
  camping,
  fishing,
  hunting,
  safety,
  cleaning,
  storage,
  kitchen,
  bathroom,
  furniture,
  lighting,
  other,
}

/// Represents an item type with translations
class ItemType {
  final String id;
  final ItemCategory category;
  final String defaultUnit;
  final Map<String, String> translations;
  final Map<String, dynamic>? defaultSpecs;

  const ItemType({
    required this.id,
    required this.category,
    this.defaultUnit = 'units',
    this.translations = const {},
    this.defaultSpecs,
  });

  /// Get localized name
  String getName(String langCode) {
    return translations[langCode] ?? id.replaceAll('_', ' ');
  }
}

/// Catalog of all item types organized by category
class ItemTypeCatalog {
  ItemTypeCatalog._();

  // Food items
  static const List<ItemType> food = [
    ItemType(
      id: 'rice',
      category: ItemCategory.food,
      defaultUnit: 'kilograms',
      translations: {'EN': 'Rice', 'PT': 'Arroz', 'ES': 'Arroz', 'FR': 'Riz', 'DE': 'Reis'},
    ),
    ItemType(
      id: 'pasta',
      category: ItemCategory.food,
      defaultUnit: 'kilograms',
      translations: {'EN': 'Pasta', 'PT': 'Massa', 'ES': 'Pasta', 'FR': 'Pâtes', 'DE': 'Nudeln'},
    ),
    ItemType(
      id: 'bread',
      category: ItemCategory.food,
      defaultUnit: 'units',
      translations: {'EN': 'Bread', 'PT': 'Pão', 'ES': 'Pan', 'FR': 'Pain', 'DE': 'Brot'},
    ),
    ItemType(
      id: 'flour',
      category: ItemCategory.food,
      defaultUnit: 'kilograms',
      translations: {'EN': 'Flour', 'PT': 'Farinha', 'ES': 'Harina', 'FR': 'Farine', 'DE': 'Mehl'},
    ),
    ItemType(
      id: 'sugar',
      category: ItemCategory.food,
      defaultUnit: 'kilograms',
      translations: {'EN': 'Sugar', 'PT': 'Açúcar', 'ES': 'Azúcar', 'FR': 'Sucre', 'DE': 'Zucker'},
    ),
    ItemType(
      id: 'salt',
      category: ItemCategory.food,
      defaultUnit: 'kilograms',
      translations: {'EN': 'Salt', 'PT': 'Sal', 'ES': 'Sal', 'FR': 'Sel', 'DE': 'Salz'},
    ),
    ItemType(
      id: 'cooking_oil',
      category: ItemCategory.food,
      defaultUnit: 'liters',
      translations: {'EN': 'Cooking Oil', 'PT': 'Óleo de Cozinha', 'ES': 'Aceite de Cocina', 'FR': 'Huile de Cuisson', 'DE': 'Speiseöl'},
    ),
    ItemType(
      id: 'olive_oil',
      category: ItemCategory.food,
      defaultUnit: 'liters',
      translations: {'EN': 'Olive Oil', 'PT': 'Azeite', 'ES': 'Aceite de Oliva', 'FR': 'Huile d\'Olive', 'DE': 'Olivenöl'},
    ),
    ItemType(
      id: 'butter',
      category: ItemCategory.food,
      defaultUnit: 'grams',
      translations: {'EN': 'Butter', 'PT': 'Manteiga', 'ES': 'Mantequilla', 'FR': 'Beurre', 'DE': 'Butter'},
    ),
    ItemType(
      id: 'eggs',
      category: ItemCategory.food,
      defaultUnit: 'units',
      translations: {'EN': 'Eggs', 'PT': 'Ovos', 'ES': 'Huevos', 'FR': 'Œufs', 'DE': 'Eier'},
    ),
    ItemType(
      id: 'milk',
      category: ItemCategory.food,
      defaultUnit: 'liters',
      translations: {'EN': 'Milk', 'PT': 'Leite', 'ES': 'Leche', 'FR': 'Lait', 'DE': 'Milch'},
    ),
    ItemType(
      id: 'cheese',
      category: ItemCategory.food,
      defaultUnit: 'grams',
      translations: {'EN': 'Cheese', 'PT': 'Queijo', 'ES': 'Queso', 'FR': 'Fromage', 'DE': 'Käse'},
    ),
    ItemType(
      id: 'yogurt',
      category: ItemCategory.food,
      defaultUnit: 'units',
      translations: {'EN': 'Yogurt', 'PT': 'Iogurte', 'ES': 'Yogur', 'FR': 'Yaourt', 'DE': 'Joghurt'},
    ),
    ItemType(
      id: 'canned_food',
      category: ItemCategory.food,
      defaultUnit: 'cans',
      translations: {'EN': 'Canned Food', 'PT': 'Comida Enlatada', 'ES': 'Comida Enlatada', 'FR': 'Conserves', 'DE': 'Konserven'},
    ),
    ItemType(
      id: 'beans',
      category: ItemCategory.food,
      defaultUnit: 'kilograms',
      translations: {'EN': 'Beans', 'PT': 'Feijão', 'ES': 'Frijoles', 'FR': 'Haricots', 'DE': 'Bohnen'},
    ),
    ItemType(
      id: 'lentils',
      category: ItemCategory.food,
      defaultUnit: 'kilograms',
      translations: {'EN': 'Lentils', 'PT': 'Lentilhas', 'ES': 'Lentejas', 'FR': 'Lentilles', 'DE': 'Linsen'},
    ),
    ItemType(
      id: 'chickpeas',
      category: ItemCategory.food,
      defaultUnit: 'kilograms',
      translations: {'EN': 'Chickpeas', 'PT': 'Grão-de-bico', 'ES': 'Garbanzos', 'FR': 'Pois Chiches', 'DE': 'Kichererbsen'},
    ),
    ItemType(
      id: 'oats',
      category: ItemCategory.food,
      defaultUnit: 'kilograms',
      translations: {'EN': 'Oats', 'PT': 'Aveia', 'ES': 'Avena', 'FR': 'Avoine', 'DE': 'Hafer'},
    ),
    ItemType(
      id: 'cereal',
      category: ItemCategory.food,
      defaultUnit: 'boxes',
      translations: {'EN': 'Cereal', 'PT': 'Cereais', 'ES': 'Cereales', 'FR': 'Céréales', 'DE': 'Müsli'},
    ),
    ItemType(
      id: 'honey',
      category: ItemCategory.food,
      defaultUnit: 'grams',
      translations: {'EN': 'Honey', 'PT': 'Mel', 'ES': 'Miel', 'FR': 'Miel', 'DE': 'Honig'},
    ),
    ItemType(
      id: 'jam',
      category: ItemCategory.food,
      defaultUnit: 'grams',
      translations: {'EN': 'Jam', 'PT': 'Compota', 'ES': 'Mermelada', 'FR': 'Confiture', 'DE': 'Marmelade'},
    ),
    ItemType(
      id: 'peanut_butter',
      category: ItemCategory.food,
      defaultUnit: 'grams',
      translations: {'EN': 'Peanut Butter', 'PT': 'Manteiga de Amendoim', 'ES': 'Mantequilla de Maní', 'FR': 'Beurre de Cacahuète', 'DE': 'Erdnussbutter'},
    ),
    ItemType(
      id: 'chocolate',
      category: ItemCategory.food,
      defaultUnit: 'grams',
      translations: {'EN': 'Chocolate', 'PT': 'Chocolate', 'ES': 'Chocolate', 'FR': 'Chocolat', 'DE': 'Schokolade'},
    ),
    ItemType(
      id: 'nuts',
      category: ItemCategory.food,
      defaultUnit: 'grams',
      translations: {'EN': 'Nuts', 'PT': 'Frutos Secos', 'ES': 'Nueces', 'FR': 'Noix', 'DE': 'Nüsse'},
    ),
    ItemType(
      id: 'dried_fruit',
      category: ItemCategory.food,
      defaultUnit: 'grams',
      translations: {'EN': 'Dried Fruit', 'PT': 'Frutas Secas', 'ES': 'Frutas Secas', 'FR': 'Fruits Secs', 'DE': 'Trockenfrüchte'},
    ),
    ItemType(
      id: 'spices',
      category: ItemCategory.food,
      defaultUnit: 'grams',
      translations: {'EN': 'Spices', 'PT': 'Especiarias', 'ES': 'Especias', 'FR': 'Épices', 'DE': 'Gewürze'},
    ),
    ItemType(
      id: 'vinegar',
      category: ItemCategory.food,
      defaultUnit: 'liters',
      translations: {'EN': 'Vinegar', 'PT': 'Vinagre', 'ES': 'Vinagre', 'FR': 'Vinaigre', 'DE': 'Essig'},
    ),
    ItemType(
      id: 'soy_sauce',
      category: ItemCategory.food,
      defaultUnit: 'milliliters',
      translations: {'EN': 'Soy Sauce', 'PT': 'Molho de Soja', 'ES': 'Salsa de Soja', 'FR': 'Sauce Soja', 'DE': 'Sojasoße'},
    ),
    ItemType(
      id: 'ketchup',
      category: ItemCategory.food,
      defaultUnit: 'grams',
      translations: {'EN': 'Ketchup', 'PT': 'Ketchup', 'ES': 'Ketchup', 'FR': 'Ketchup', 'DE': 'Ketchup'},
    ),
    ItemType(
      id: 'mustard',
      category: ItemCategory.food,
      defaultUnit: 'grams',
      translations: {'EN': 'Mustard', 'PT': 'Mostarda', 'ES': 'Mostaza', 'FR': 'Moutarde', 'DE': 'Senf'},
    ),
    ItemType(
      id: 'mayonnaise',
      category: ItemCategory.food,
      defaultUnit: 'grams',
      translations: {'EN': 'Mayonnaise', 'PT': 'Maionese', 'ES': 'Mayonesa', 'FR': 'Mayonnaise', 'DE': 'Mayonnaise'},
    ),
    ItemType(
      id: 'tomato_sauce',
      category: ItemCategory.food,
      defaultUnit: 'grams',
      translations: {'EN': 'Tomato Sauce', 'PT': 'Molho de Tomate', 'ES': 'Salsa de Tomate', 'FR': 'Sauce Tomate', 'DE': 'Tomatensoße'},
    ),
    ItemType(
      id: 'frozen_vegetables',
      category: ItemCategory.food,
      defaultUnit: 'grams',
      translations: {'EN': 'Frozen Vegetables', 'PT': 'Vegetais Congelados', 'ES': 'Verduras Congeladas', 'FR': 'Légumes Surgelés', 'DE': 'Tiefkühlgemüse'},
    ),
    ItemType(
      id: 'frozen_meat',
      category: ItemCategory.food,
      defaultUnit: 'kilograms',
      translations: {'EN': 'Frozen Meat', 'PT': 'Carne Congelada', 'ES': 'Carne Congelada', 'FR': 'Viande Surgelée', 'DE': 'Tiefkühlfleisch'},
    ),
    ItemType(
      id: 'frozen_fish',
      category: ItemCategory.food,
      defaultUnit: 'kilograms',
      translations: {'EN': 'Frozen Fish', 'PT': 'Peixe Congelado', 'ES': 'Pescado Congelado', 'FR': 'Poisson Surgelé', 'DE': 'Tiefkühlfisch'},
    ),
    ItemType(
      id: 'coffee',
      category: ItemCategory.food,
      defaultUnit: 'grams',
      translations: {'EN': 'Coffee', 'PT': 'Café', 'ES': 'Café', 'FR': 'Café', 'DE': 'Kaffee'},
    ),
    ItemType(
      id: 'tea',
      category: ItemCategory.food,
      defaultUnit: 'grams',
      translations: {'EN': 'Tea', 'PT': 'Chá', 'ES': 'Té', 'FR': 'Thé', 'DE': 'Tee'},
    ),
    ItemType(
      id: 'cocoa',
      category: ItemCategory.food,
      defaultUnit: 'grams',
      translations: {'EN': 'Cocoa', 'PT': 'Cacau', 'ES': 'Cacao', 'FR': 'Cacao', 'DE': 'Kakao'},
    ),
    ItemType(
      id: 'baking_powder',
      category: ItemCategory.food,
      defaultUnit: 'grams',
      translations: {'EN': 'Baking Powder', 'PT': 'Fermento', 'ES': 'Levadura', 'FR': 'Levure', 'DE': 'Backpulver'},
    ),
  ];

  // Beverages
  static const List<ItemType> beverages = [
    ItemType(
      id: 'water_bottle',
      category: ItemCategory.beverages,
      defaultUnit: 'bottles',
      translations: {'EN': 'Water Bottle', 'PT': 'Garrafa de Água', 'ES': 'Botella de Agua', 'FR': 'Bouteille d\'Eau', 'DE': 'Wasserflasche'},
    ),
    ItemType(
      id: 'juice',
      category: ItemCategory.beverages,
      defaultUnit: 'liters',
      translations: {'EN': 'Juice', 'PT': 'Sumo', 'ES': 'Jugo', 'FR': 'Jus', 'DE': 'Saft'},
    ),
    ItemType(
      id: 'soda',
      category: ItemCategory.beverages,
      defaultUnit: 'cans',
      translations: {'EN': 'Soda', 'PT': 'Refrigerante', 'ES': 'Refresco', 'FR': 'Soda', 'DE': 'Limonade'},
    ),
    ItemType(
      id: 'beer',
      category: ItemCategory.beverages,
      defaultUnit: 'bottles',
      translations: {'EN': 'Beer', 'PT': 'Cerveja', 'ES': 'Cerveza', 'FR': 'Bière', 'DE': 'Bier'},
    ),
    ItemType(
      id: 'wine',
      category: ItemCategory.beverages,
      defaultUnit: 'bottles',
      translations: {'EN': 'Wine', 'PT': 'Vinho', 'ES': 'Vino', 'FR': 'Vin', 'DE': 'Wein'},
    ),
    ItemType(
      id: 'spirits',
      category: ItemCategory.beverages,
      defaultUnit: 'bottles',
      translations: {'EN': 'Spirits', 'PT': 'Bebidas Espirituosas', 'ES': 'Licores', 'FR': 'Spiritueux', 'DE': 'Spirituosen'},
    ),
    ItemType(
      id: 'energy_drink',
      category: ItemCategory.beverages,
      defaultUnit: 'cans',
      translations: {'EN': 'Energy Drink', 'PT': 'Bebida Energética', 'ES': 'Bebida Energética', 'FR': 'Boisson Énergétique', 'DE': 'Energydrink'},
    ),
    ItemType(
      id: 'sports_drink',
      category: ItemCategory.beverages,
      defaultUnit: 'bottles',
      translations: {'EN': 'Sports Drink', 'PT': 'Bebida Desportiva', 'ES': 'Bebida Deportiva', 'FR': 'Boisson Sportive', 'DE': 'Sportgetränk'},
    ),
  ];

  // Household items
  static const List<ItemType> household = [
    ItemType(
      id: 'toilet_paper',
      category: ItemCategory.household,
      defaultUnit: 'rolls',
      translations: {'EN': 'Toilet Paper', 'PT': 'Papel Higiénico', 'ES': 'Papel Higiénico', 'FR': 'Papier Toilette', 'DE': 'Toilettenpapier'},
    ),
    ItemType(
      id: 'paper_towels',
      category: ItemCategory.household,
      defaultUnit: 'rolls',
      translations: {'EN': 'Paper Towels', 'PT': 'Toalhas de Papel', 'ES': 'Toallas de Papel', 'FR': 'Essuie-tout', 'DE': 'Küchenpapier'},
    ),
    ItemType(
      id: 'trash_bags',
      category: ItemCategory.household,
      defaultUnit: 'units',
      translations: {'EN': 'Trash Bags', 'PT': 'Sacos do Lixo', 'ES': 'Bolsas de Basura', 'FR': 'Sacs Poubelle', 'DE': 'Müllbeutel'},
    ),
    ItemType(
      id: 'aluminum_foil',
      category: ItemCategory.household,
      defaultUnit: 'rolls',
      translations: {'EN': 'Aluminum Foil', 'PT': 'Papel de Alumínio', 'ES': 'Papel de Aluminio', 'FR': 'Papier Aluminium', 'DE': 'Alufolie'},
    ),
    ItemType(
      id: 'plastic_wrap',
      category: ItemCategory.household,
      defaultUnit: 'rolls',
      translations: {'EN': 'Plastic Wrap', 'PT': 'Película Aderente', 'ES': 'Film Plástico', 'FR': 'Film Plastique', 'DE': 'Frischhaltefolie'},
    ),
    ItemType(
      id: 'zip_bags',
      category: ItemCategory.household,
      defaultUnit: 'boxes',
      translations: {'EN': 'Zip Bags', 'PT': 'Sacos Zip', 'ES': 'Bolsas Zip', 'FR': 'Sacs Zip', 'DE': 'Zip-Beutel'},
    ),
    ItemType(
      id: 'light_bulbs',
      category: ItemCategory.household,
      defaultUnit: 'units',
      translations: {'EN': 'Light Bulbs', 'PT': 'Lâmpadas', 'ES': 'Bombillas', 'FR': 'Ampoules', 'DE': 'Glühbirnen'},
    ),
    ItemType(
      id: 'batteries',
      category: ItemCategory.household,
      defaultUnit: 'units',
      translations: {'EN': 'Batteries', 'PT': 'Pilhas', 'ES': 'Pilas', 'FR': 'Piles', 'DE': 'Batterien'},
    ),
    ItemType(
      id: 'candles',
      category: ItemCategory.household,
      defaultUnit: 'units',
      translations: {'EN': 'Candles', 'PT': 'Velas', 'ES': 'Velas', 'FR': 'Bougies', 'DE': 'Kerzen'},
    ),
    ItemType(
      id: 'matches',
      category: ItemCategory.household,
      defaultUnit: 'boxes',
      translations: {'EN': 'Matches', 'PT': 'Fósforos', 'ES': 'Cerillas', 'FR': 'Allumettes', 'DE': 'Streichhölzer'},
    ),
    ItemType(
      id: 'lighters',
      category: ItemCategory.household,
      defaultUnit: 'units',
      translations: {'EN': 'Lighters', 'PT': 'Isqueiros', 'ES': 'Encendedores', 'FR': 'Briquets', 'DE': 'Feuerzeuge'},
    ),
    ItemType(
      id: 'sponges',
      category: ItemCategory.household,
      defaultUnit: 'units',
      translations: {'EN': 'Sponges', 'PT': 'Esponjas', 'ES': 'Esponjas', 'FR': 'Éponges', 'DE': 'Schwämme'},
    ),
    ItemType(
      id: 'cleaning_cloths',
      category: ItemCategory.household,
      defaultUnit: 'units',
      translations: {'EN': 'Cleaning Cloths', 'PT': 'Panos de Limpeza', 'ES': 'Paños de Limpieza', 'FR': 'Chiffons', 'DE': 'Putzlappen'},
    ),
    ItemType(
      id: 'mop_heads',
      category: ItemCategory.household,
      defaultUnit: 'units',
      translations: {'EN': 'Mop Heads', 'PT': 'Cabeças de Esfregona', 'ES': 'Cabezas de Fregona', 'FR': 'Têtes de Balai', 'DE': 'Wischköpfe'},
    ),
    ItemType(
      id: 'broom',
      category: ItemCategory.household,
      defaultUnit: 'units',
      translations: {'EN': 'Broom', 'PT': 'Vassoura', 'ES': 'Escoba', 'FR': 'Balai', 'DE': 'Besen'},
    ),
    ItemType(
      id: 'dustpan',
      category: ItemCategory.household,
      defaultUnit: 'units',
      translations: {'EN': 'Dustpan', 'PT': 'Pá do Lixo', 'ES': 'Recogedor', 'FR': 'Pelle', 'DE': 'Kehrschaufel'},
    ),
  ];

  // Cleaning supplies
  static const List<ItemType> cleaning = [
    ItemType(
      id: 'dish_soap',
      category: ItemCategory.cleaning,
      defaultUnit: 'liters',
      translations: {'EN': 'Dish Soap', 'PT': 'Detergente da Loiça', 'ES': 'Jabón para Platos', 'FR': 'Liquide Vaisselle', 'DE': 'Spülmittel'},
    ),
    ItemType(
      id: 'laundry_detergent',
      category: ItemCategory.cleaning,
      defaultUnit: 'liters',
      translations: {'EN': 'Laundry Detergent', 'PT': 'Detergente da Roupa', 'ES': 'Detergente para Ropa', 'FR': 'Lessive', 'DE': 'Waschmittel'},
    ),
    ItemType(
      id: 'fabric_softener',
      category: ItemCategory.cleaning,
      defaultUnit: 'liters',
      translations: {'EN': 'Fabric Softener', 'PT': 'Amaciador', 'ES': 'Suavizante', 'FR': 'Assouplissant', 'DE': 'Weichspüler'},
    ),
    ItemType(
      id: 'bleach',
      category: ItemCategory.cleaning,
      defaultUnit: 'liters',
      translations: {'EN': 'Bleach', 'PT': 'Lixívia', 'ES': 'Lejía', 'FR': 'Eau de Javel', 'DE': 'Bleichmittel'},
    ),
    ItemType(
      id: 'all_purpose_cleaner',
      category: ItemCategory.cleaning,
      defaultUnit: 'liters',
      translations: {'EN': 'All-Purpose Cleaner', 'PT': 'Limpeza Multiusos', 'ES': 'Limpiador Multiusos', 'FR': 'Nettoyant Multi-usages', 'DE': 'Allzweckreiniger'},
    ),
    ItemType(
      id: 'glass_cleaner',
      category: ItemCategory.cleaning,
      defaultUnit: 'liters',
      translations: {'EN': 'Glass Cleaner', 'PT': 'Limpa-vidros', 'ES': 'Limpiacristales', 'FR': 'Nettoyant Vitres', 'DE': 'Glasreiniger'},
    ),
    ItemType(
      id: 'floor_cleaner',
      category: ItemCategory.cleaning,
      defaultUnit: 'liters',
      translations: {'EN': 'Floor Cleaner', 'PT': 'Limpa-chão', 'ES': 'Limpiador de Suelos', 'FR': 'Nettoyant Sol', 'DE': 'Bodenreiniger'},
    ),
    ItemType(
      id: 'bathroom_cleaner',
      category: ItemCategory.cleaning,
      defaultUnit: 'liters',
      translations: {'EN': 'Bathroom Cleaner', 'PT': 'Limpa Casa de Banho', 'ES': 'Limpiador de Baño', 'FR': 'Nettoyant Salle de Bain', 'DE': 'Badreiniger'},
    ),
    ItemType(
      id: 'toilet_cleaner',
      category: ItemCategory.cleaning,
      defaultUnit: 'liters',
      translations: {'EN': 'Toilet Cleaner', 'PT': 'Limpa-sanitas', 'ES': 'Limpiador de Inodoro', 'FR': 'Nettoyant WC', 'DE': 'WC-Reiniger'},
    ),
    ItemType(
      id: 'disinfectant',
      category: ItemCategory.cleaning,
      defaultUnit: 'liters',
      translations: {'EN': 'Disinfectant', 'PT': 'Desinfetante', 'ES': 'Desinfectante', 'FR': 'Désinfectant', 'DE': 'Desinfektionsmittel'},
    ),
    ItemType(
      id: 'air_freshener',
      category: ItemCategory.cleaning,
      defaultUnit: 'units',
      translations: {'EN': 'Air Freshener', 'PT': 'Ambientador', 'ES': 'Ambientador', 'FR': 'Désodorisant', 'DE': 'Lufterfrischer'},
    ),
    ItemType(
      id: 'stain_remover',
      category: ItemCategory.cleaning,
      defaultUnit: 'liters',
      translations: {'EN': 'Stain Remover', 'PT': 'Tira-nódoas', 'ES': 'Quitamanchas', 'FR': 'Détachant', 'DE': 'Fleckenentferner'},
    ),
  ];

  // Medical/First Aid
  static const List<ItemType> medical = [
    ItemType(
      id: 'bandages',
      category: ItemCategory.medical,
      defaultUnit: 'units',
      translations: {'EN': 'Bandages', 'PT': 'Pensos', 'ES': 'Vendas', 'FR': 'Pansements', 'DE': 'Pflaster'},
    ),
    ItemType(
      id: 'gauze',
      category: ItemCategory.medical,
      defaultUnit: 'rolls',
      translations: {'EN': 'Gauze', 'PT': 'Gaze', 'ES': 'Gasa', 'FR': 'Gaze', 'DE': 'Gaze'},
    ),
    ItemType(
      id: 'antiseptic',
      category: ItemCategory.medical,
      defaultUnit: 'milliliters',
      translations: {'EN': 'Antiseptic', 'PT': 'Antisséptico', 'ES': 'Antiséptico', 'FR': 'Antiseptique', 'DE': 'Antiseptikum'},
    ),
    ItemType(
      id: 'painkillers',
      category: ItemCategory.medical,
      defaultUnit: 'units',
      translations: {'EN': 'Painkillers', 'PT': 'Analgésicos', 'ES': 'Analgésicos', 'FR': 'Analgésiques', 'DE': 'Schmerzmittel'},
    ),
    ItemType(
      id: 'cold_medicine',
      category: ItemCategory.medical,
      defaultUnit: 'units',
      translations: {'EN': 'Cold Medicine', 'PT': 'Medicamento para Constipação', 'ES': 'Medicina para el Resfriado', 'FR': 'Médicament contre le Rhume', 'DE': 'Erkältungsmedizin'},
    ),
    ItemType(
      id: 'thermometer',
      category: ItemCategory.medical,
      defaultUnit: 'units',
      translations: {'EN': 'Thermometer', 'PT': 'Termómetro', 'ES': 'Termómetro', 'FR': 'Thermomètre', 'DE': 'Thermometer'},
    ),
    ItemType(
      id: 'first_aid_kit',
      category: ItemCategory.medical,
      defaultUnit: 'units',
      translations: {'EN': 'First Aid Kit', 'PT': 'Kit de Primeiros Socorros', 'ES': 'Botiquín', 'FR': 'Trousse de Secours', 'DE': 'Erste-Hilfe-Set'},
    ),
    ItemType(
      id: 'medical_gloves',
      category: ItemCategory.medical,
      defaultUnit: 'pairs',
      translations: {'EN': 'Medical Gloves', 'PT': 'Luvas Médicas', 'ES': 'Guantes Médicos', 'FR': 'Gants Médicaux', 'DE': 'Medizinische Handschuhe'},
    ),
    ItemType(
      id: 'face_masks',
      category: ItemCategory.medical,
      defaultUnit: 'units',
      translations: {'EN': 'Face Masks', 'PT': 'Máscaras', 'ES': 'Mascarillas', 'FR': 'Masques', 'DE': 'Gesichtsmasken'},
    ),
    ItemType(
      id: 'hand_sanitizer',
      category: ItemCategory.medical,
      defaultUnit: 'milliliters',
      translations: {'EN': 'Hand Sanitizer', 'PT': 'Gel Desinfetante', 'ES': 'Gel Desinfectante', 'FR': 'Gel Hydroalcoolique', 'DE': 'Handdesinfektionsmittel'},
    ),
    ItemType(
      id: 'vitamins',
      category: ItemCategory.medical,
      defaultUnit: 'units',
      translations: {'EN': 'Vitamins', 'PT': 'Vitaminas', 'ES': 'Vitaminas', 'FR': 'Vitamines', 'DE': 'Vitamine'},
    ),
    ItemType(
      id: 'sunscreen',
      category: ItemCategory.medical,
      defaultUnit: 'milliliters',
      translations: {'EN': 'Sunscreen', 'PT': 'Protetor Solar', 'ES': 'Protector Solar', 'FR': 'Crème Solaire', 'DE': 'Sonnenschutz'},
    ),
    ItemType(
      id: 'insect_repellent',
      category: ItemCategory.medical,
      defaultUnit: 'milliliters',
      translations: {'EN': 'Insect Repellent', 'PT': 'Repelente de Insetos', 'ES': 'Repelente de Insectos', 'FR': 'Répulsif Insectes', 'DE': 'Insektenschutzmittel'},
    ),
  ];

  // Tools
  static const List<ItemType> tools = [
    ItemType(
      id: 'hammer',
      category: ItemCategory.tools,
      defaultUnit: 'units',
      translations: {'EN': 'Hammer', 'PT': 'Martelo', 'ES': 'Martillo', 'FR': 'Marteau', 'DE': 'Hammer'},
    ),
    ItemType(
      id: 'screwdriver',
      category: ItemCategory.tools,
      defaultUnit: 'units',
      translations: {'EN': 'Screwdriver', 'PT': 'Chave de Fendas', 'ES': 'Destornillador', 'FR': 'Tournevis', 'DE': 'Schraubenzieher'},
    ),
    ItemType(
      id: 'wrench',
      category: ItemCategory.tools,
      defaultUnit: 'units',
      translations: {'EN': 'Wrench', 'PT': 'Chave Inglesa', 'ES': 'Llave Inglesa', 'FR': 'Clé', 'DE': 'Schraubenschlüssel'},
    ),
    ItemType(
      id: 'pliers',
      category: ItemCategory.tools,
      defaultUnit: 'units',
      translations: {'EN': 'Pliers', 'PT': 'Alicate', 'ES': 'Alicates', 'FR': 'Pinces', 'DE': 'Zange'},
    ),
    ItemType(
      id: 'tape_measure',
      category: ItemCategory.tools,
      defaultUnit: 'units',
      translations: {'EN': 'Tape Measure', 'PT': 'Fita Métrica', 'ES': 'Cinta Métrica', 'FR': 'Mètre Ruban', 'DE': 'Maßband'},
    ),
    ItemType(
      id: 'level',
      category: ItemCategory.tools,
      defaultUnit: 'units',
      translations: {'EN': 'Level', 'PT': 'Nível', 'ES': 'Nivel', 'FR': 'Niveau', 'DE': 'Wasserwaage'},
    ),
    ItemType(
      id: 'drill',
      category: ItemCategory.tools,
      defaultUnit: 'units',
      translations: {'EN': 'Drill', 'PT': 'Berbequim', 'ES': 'Taladro', 'FR': 'Perceuse', 'DE': 'Bohrmaschine'},
    ),
    ItemType(
      id: 'drill_bits',
      category: ItemCategory.tools,
      defaultUnit: 'units',
      translations: {'EN': 'Drill Bits', 'PT': 'Brocas', 'ES': 'Brocas', 'FR': 'Forets', 'DE': 'Bohrer'},
    ),
    ItemType(
      id: 'saw',
      category: ItemCategory.tools,
      defaultUnit: 'units',
      translations: {'EN': 'Saw', 'PT': 'Serra', 'ES': 'Sierra', 'FR': 'Scie', 'DE': 'Säge'},
    ),
    ItemType(
      id: 'nails',
      category: ItemCategory.tools,
      defaultUnit: 'units',
      translations: {'EN': 'Nails', 'PT': 'Pregos', 'ES': 'Clavos', 'FR': 'Clous', 'DE': 'Nägel'},
    ),
    ItemType(
      id: 'screws',
      category: ItemCategory.tools,
      defaultUnit: 'units',
      translations: {'EN': 'Screws', 'PT': 'Parafusos', 'ES': 'Tornillos', 'FR': 'Vis', 'DE': 'Schrauben'},
    ),
    ItemType(
      id: 'bolts',
      category: ItemCategory.tools,
      defaultUnit: 'units',
      translations: {'EN': 'Bolts', 'PT': 'Pernos', 'ES': 'Pernos', 'FR': 'Boulons', 'DE': 'Bolzen'},
    ),
    ItemType(
      id: 'nuts',
      category: ItemCategory.tools,
      defaultUnit: 'units',
      translations: {'EN': 'Nuts', 'PT': 'Porcas', 'ES': 'Tuercas', 'FR': 'Écrous', 'DE': 'Muttern'},
    ),
    ItemType(
      id: 'washers',
      category: ItemCategory.tools,
      defaultUnit: 'units',
      translations: {'EN': 'Washers', 'PT': 'Anilhas', 'ES': 'Arandelas', 'FR': 'Rondelles', 'DE': 'Unterlegscheiben'},
    ),
    ItemType(
      id: 'duct_tape',
      category: ItemCategory.tools,
      defaultUnit: 'rolls',
      translations: {'EN': 'Duct Tape', 'PT': 'Fita Adesiva', 'ES': 'Cinta Adhesiva', 'FR': 'Ruban Adhésif', 'DE': 'Klebeband'},
    ),
    ItemType(
      id: 'electrical_tape',
      category: ItemCategory.tools,
      defaultUnit: 'rolls',
      translations: {'EN': 'Electrical Tape', 'PT': 'Fita Isoladora', 'ES': 'Cinta Aislante', 'FR': 'Ruban Isolant', 'DE': 'Isolierband'},
    ),
    ItemType(
      id: 'sandpaper',
      category: ItemCategory.tools,
      defaultUnit: 'sheets',
      translations: {'EN': 'Sandpaper', 'PT': 'Lixa', 'ES': 'Lija', 'FR': 'Papier de Verre', 'DE': 'Schleifpapier'},
    ),
    ItemType(
      id: 'glue',
      category: ItemCategory.tools,
      defaultUnit: 'units',
      translations: {'EN': 'Glue', 'PT': 'Cola', 'ES': 'Pegamento', 'FR': 'Colle', 'DE': 'Kleber'},
    ),
    ItemType(
      id: 'epoxy',
      category: ItemCategory.tools,
      defaultUnit: 'units',
      translations: {'EN': 'Epoxy', 'PT': 'Epóxi', 'ES': 'Epoxi', 'FR': 'Époxy', 'DE': 'Epoxid'},
    ),
    ItemType(
      id: 'cable_ties',
      category: ItemCategory.tools,
      defaultUnit: 'units',
      translations: {'EN': 'Cable Ties', 'PT': 'Abraçadeiras', 'ES': 'Bridas', 'FR': 'Colliers de Serrage', 'DE': 'Kabelbinder'},
    ),
    ItemType(
      id: 'rope',
      category: ItemCategory.tools,
      defaultUnit: 'meters',
      translations: {'EN': 'Rope', 'PT': 'Corda', 'ES': 'Cuerda', 'FR': 'Corde', 'DE': 'Seil'},
    ),
    ItemType(
      id: 'wire',
      category: ItemCategory.tools,
      defaultUnit: 'meters',
      translations: {'EN': 'Wire', 'PT': 'Arame', 'ES': 'Alambre', 'FR': 'Fil', 'DE': 'Draht'},
    ),
    ItemType(
      id: 'chain',
      category: ItemCategory.tools,
      defaultUnit: 'meters',
      translations: {'EN': 'Chain', 'PT': 'Corrente', 'ES': 'Cadena', 'FR': 'Chaîne', 'DE': 'Kette'},
    ),
    ItemType(
      id: 'knife',
      category: ItemCategory.tools,
      defaultUnit: 'units',
      translations: {'EN': 'Knife', 'PT': 'Faca', 'ES': 'Cuchillo', 'FR': 'Couteau', 'DE': 'Messer'},
    ),
    ItemType(
      id: 'utility_knife',
      category: ItemCategory.tools,
      defaultUnit: 'units',
      translations: {'EN': 'Utility Knife', 'PT': 'X-ato', 'ES': 'Cúter', 'FR': 'Cutter', 'DE': 'Teppichmesser'},
    ),
    ItemType(
      id: 'pocket_knife',
      category: ItemCategory.tools,
      defaultUnit: 'units',
      translations: {'EN': 'Pocket Knife', 'PT': 'Canivete', 'ES': 'Navaja', 'FR': 'Canif', 'DE': 'Taschenmesser'},
    ),
    ItemType(
      id: 'scissors',
      category: ItemCategory.tools,
      defaultUnit: 'units',
      translations: {'EN': 'Scissors', 'PT': 'Tesoura', 'ES': 'Tijeras', 'FR': 'Ciseaux', 'DE': 'Schere'},
    ),
    ItemType(
      id: 'axe',
      category: ItemCategory.tools,
      defaultUnit: 'units',
      translations: {'EN': 'Axe', 'PT': 'Machado', 'ES': 'Hacha', 'FR': 'Hache', 'DE': 'Axt'},
    ),
    ItemType(
      id: 'hatchet',
      category: ItemCategory.tools,
      defaultUnit: 'units',
      translations: {'EN': 'Hatchet', 'PT': 'Machadinha', 'ES': 'Hachuela', 'FR': 'Hachette', 'DE': 'Beil'},
    ),
    ItemType(
      id: 'multitool',
      category: ItemCategory.tools,
      defaultUnit: 'units',
      translations: {'EN': 'Multitool', 'PT': 'Multiferramenta', 'ES': 'Multiherramienta', 'FR': 'Multi-outil', 'DE': 'Multifunktionswerkzeug'},
    ),
  ];

  // Automotive
  static const List<ItemType> automotive = [
    ItemType(
      id: 'motor_oil',
      category: ItemCategory.automotive,
      defaultUnit: 'liters',
      translations: {'EN': 'Motor Oil', 'PT': 'Óleo do Motor', 'ES': 'Aceite de Motor', 'FR': 'Huile Moteur', 'DE': 'Motoröl'},
    ),
    ItemType(
      id: 'coolant',
      category: ItemCategory.automotive,
      defaultUnit: 'liters',
      translations: {'EN': 'Coolant', 'PT': 'Líquido de Arrefecimento', 'ES': 'Refrigerante', 'FR': 'Liquide de Refroidissement', 'DE': 'Kühlmittel'},
    ),
    ItemType(
      id: 'brake_fluid',
      category: ItemCategory.automotive,
      defaultUnit: 'liters',
      translations: {'EN': 'Brake Fluid', 'PT': 'Óleo de Travões', 'ES': 'Líquido de Frenos', 'FR': 'Liquide de Frein', 'DE': 'Bremsflüssigkeit'},
    ),
    ItemType(
      id: 'windshield_fluid',
      category: ItemCategory.automotive,
      defaultUnit: 'liters',
      translations: {'EN': 'Windshield Fluid', 'PT': 'Limpa Para-brisas', 'ES': 'Líquido Limpiaparabrisas', 'FR': 'Lave-glace', 'DE': 'Scheibenwischwasser'},
    ),
    ItemType(
      id: 'gasoline',
      category: ItemCategory.automotive,
      defaultUnit: 'liters',
      translations: {'EN': 'Gasoline', 'PT': 'Gasolina', 'ES': 'Gasolina', 'FR': 'Essence', 'DE': 'Benzin'},
    ),
    ItemType(
      id: 'diesel',
      category: ItemCategory.automotive,
      defaultUnit: 'liters',
      translations: {'EN': 'Diesel', 'PT': 'Gasóleo', 'ES': 'Diésel', 'FR': 'Diesel', 'DE': 'Diesel'},
    ),
    ItemType(
      id: 'car_battery',
      category: ItemCategory.automotive,
      defaultUnit: 'units',
      translations: {'EN': 'Car Battery', 'PT': 'Bateria de Carro', 'ES': 'Batería de Coche', 'FR': 'Batterie de Voiture', 'DE': 'Autobatterie'},
    ),
    ItemType(
      id: 'tire',
      category: ItemCategory.automotive,
      defaultUnit: 'units',
      translations: {'EN': 'Tire', 'PT': 'Pneu', 'ES': 'Neumático', 'FR': 'Pneu', 'DE': 'Reifen'},
    ),
    ItemType(
      id: 'spark_plugs',
      category: ItemCategory.automotive,
      defaultUnit: 'units',
      translations: {'EN': 'Spark Plugs', 'PT': 'Velas de Ignição', 'ES': 'Bujías', 'FR': 'Bougies', 'DE': 'Zündkerzen'},
    ),
    ItemType(
      id: 'air_filter',
      category: ItemCategory.automotive,
      defaultUnit: 'units',
      translations: {'EN': 'Air Filter', 'PT': 'Filtro de Ar', 'ES': 'Filtro de Aire', 'FR': 'Filtre à Air', 'DE': 'Luftfilter'},
    ),
    ItemType(
      id: 'oil_filter',
      category: ItemCategory.automotive,
      defaultUnit: 'units',
      translations: {'EN': 'Oil Filter', 'PT': 'Filtro de Óleo', 'ES': 'Filtro de Aceite', 'FR': 'Filtre à Huile', 'DE': 'Ölfilter'},
    ),
    ItemType(
      id: 'wiper_blades',
      category: ItemCategory.automotive,
      defaultUnit: 'pairs',
      translations: {'EN': 'Wiper Blades', 'PT': 'Escovas Limpa-vidros', 'ES': 'Escobillas Limpiaparabrisas', 'FR': 'Balais d\'Essuie-glace', 'DE': 'Scheibenwischer'},
    ),
    ItemType(
      id: 'headlight_bulbs',
      category: ItemCategory.automotive,
      defaultUnit: 'units',
      translations: {'EN': 'Headlight Bulbs', 'PT': 'Lâmpadas dos Faróis', 'ES': 'Bombillas de Faros', 'FR': 'Ampoules de Phares', 'DE': 'Scheinwerferbirnen'},
    ),
    ItemType(
      id: 'fuses',
      category: ItemCategory.automotive,
      defaultUnit: 'units',
      translations: {'EN': 'Fuses', 'PT': 'Fusíveis', 'ES': 'Fusibles', 'FR': 'Fusibles', 'DE': 'Sicherungen'},
    ),
    ItemType(
      id: 'jumper_cables',
      category: ItemCategory.automotive,
      defaultUnit: 'units',
      translations: {'EN': 'Jumper Cables', 'PT': 'Cabos de Bateria', 'ES': 'Cables de Arranque', 'FR': 'Câbles de Démarrage', 'DE': 'Starthilfekabel'},
    ),
    // Vehicles
    ItemType(
      id: 'car',
      category: ItemCategory.automotive,
      defaultUnit: 'units',
      translations: {'EN': 'Car', 'PT': 'Carro', 'ES': 'Coche', 'FR': 'Voiture', 'DE': 'Auto'},
    ),
    ItemType(
      id: 'bicycle',
      category: ItemCategory.automotive,
      defaultUnit: 'units',
      translations: {'EN': 'Bicycle', 'PT': 'Bicicleta', 'ES': 'Bicicleta', 'FR': 'Vélo', 'DE': 'Fahrrad'},
    ),
    ItemType(
      id: 'motorcycle',
      category: ItemCategory.automotive,
      defaultUnit: 'units',
      translations: {'EN': 'Motorcycle', 'PT': 'Mota', 'ES': 'Motocicleta', 'FR': 'Moto', 'DE': 'Motorrad'},
    ),
    ItemType(
      id: 'scooter',
      category: ItemCategory.automotive,
      defaultUnit: 'units',
      translations: {'EN': 'Scooter', 'PT': 'Scooter', 'ES': 'Scooter', 'FR': 'Scooter', 'DE': 'Roller'},
    ),
    ItemType(
      id: 'electric_scooter',
      category: ItemCategory.automotive,
      defaultUnit: 'units',
      translations: {'EN': 'Electric Scooter', 'PT': 'Trotinete Elétrica', 'ES': 'Patinete Eléctrico', 'FR': 'Trottinette Électrique', 'DE': 'E-Scooter'},
    ),
    ItemType(
      id: 'bus',
      category: ItemCategory.automotive,
      defaultUnit: 'units',
      translations: {'EN': 'Bus', 'PT': 'Autocarro', 'ES': 'Autobús', 'FR': 'Bus', 'DE': 'Bus'},
    ),
    ItemType(
      id: 'truck',
      category: ItemCategory.automotive,
      defaultUnit: 'units',
      translations: {'EN': 'Truck', 'PT': 'Camião', 'ES': 'Camión', 'FR': 'Camion', 'DE': 'Lastwagen'},
    ),
    ItemType(
      id: 'van',
      category: ItemCategory.automotive,
      defaultUnit: 'units',
      translations: {'EN': 'Van', 'PT': 'Carrinha', 'ES': 'Furgoneta', 'FR': 'Fourgon', 'DE': 'Transporter'},
    ),
    ItemType(
      id: 'trailer',
      category: ItemCategory.automotive,
      defaultUnit: 'units',
      translations: {'EN': 'Trailer', 'PT': 'Reboque', 'ES': 'Remolque', 'FR': 'Remorque', 'DE': 'Anhänger'},
    ),
    ItemType(
      id: 'caravan',
      category: ItemCategory.automotive,
      defaultUnit: 'units',
      translations: {'EN': 'Caravan', 'PT': 'Caravana', 'ES': 'Caravana', 'FR': 'Caravane', 'DE': 'Wohnwagen'},
    ),
    ItemType(
      id: 'motorhome',
      category: ItemCategory.automotive,
      defaultUnit: 'units',
      translations: {'EN': 'Motorhome', 'PT': 'Autocaravana', 'ES': 'Autocaravana', 'FR': 'Camping-car', 'DE': 'Wohnmobil'},
    ),
    ItemType(
      id: 'quad_bike',
      category: ItemCategory.automotive,
      defaultUnit: 'units',
      translations: {'EN': 'Quad Bike', 'PT': 'Moto 4', 'ES': 'Quad', 'FR': 'Quad', 'DE': 'Quad'},
    ),
    ItemType(
      id: 'tractor',
      category: ItemCategory.automotive,
      defaultUnit: 'units',
      translations: {'EN': 'Tractor', 'PT': 'Trator', 'ES': 'Tractor', 'FR': 'Tracteur', 'DE': 'Traktor'},
    ),
    ItemType(
      id: 'forklift',
      category: ItemCategory.automotive,
      defaultUnit: 'units',
      translations: {'EN': 'Forklift', 'PT': 'Empilhador', 'ES': 'Carretilla Elevadora', 'FR': 'Chariot Élévateur', 'DE': 'Gabelstapler'},
    ),
    ItemType(
      id: 'boat',
      category: ItemCategory.automotive,
      defaultUnit: 'units',
      translations: {'EN': 'Boat', 'PT': 'Barco', 'ES': 'Barco', 'FR': 'Bateau', 'DE': 'Boot'},
    ),
    ItemType(
      id: 'jet_ski',
      category: ItemCategory.automotive,
      defaultUnit: 'units',
      translations: {'EN': 'Jet Ski', 'PT': 'Mota de Água', 'ES': 'Moto de Agua', 'FR': 'Jet Ski', 'DE': 'Jetski'},
    ),
  ];

  // Garden
  static const List<ItemType> garden = [
    ItemType(
      id: 'seeds',
      category: ItemCategory.garden,
      defaultUnit: 'packs',
      translations: {'EN': 'Seeds', 'PT': 'Sementes', 'ES': 'Semillas', 'FR': 'Graines', 'DE': 'Samen'},
    ),
    ItemType(
      id: 'fertilizer',
      category: ItemCategory.garden,
      defaultUnit: 'kilograms',
      translations: {'EN': 'Fertilizer', 'PT': 'Fertilizante', 'ES': 'Fertilizante', 'FR': 'Engrais', 'DE': 'Dünger'},
    ),
    ItemType(
      id: 'potting_soil',
      category: ItemCategory.garden,
      defaultUnit: 'liters',
      translations: {'EN': 'Potting Soil', 'PT': 'Terra para Vasos', 'ES': 'Tierra para Macetas', 'FR': 'Terreau', 'DE': 'Blumenerde'},
    ),
    ItemType(
      id: 'mulch',
      category: ItemCategory.garden,
      defaultUnit: 'kilograms',
      translations: {'EN': 'Mulch', 'PT': 'Cobertura Vegetal', 'ES': 'Mantillo', 'FR': 'Paillis', 'DE': 'Mulch'},
    ),
    ItemType(
      id: 'pesticide',
      category: ItemCategory.garden,
      defaultUnit: 'liters',
      translations: {'EN': 'Pesticide', 'PT': 'Pesticida', 'ES': 'Pesticida', 'FR': 'Pesticide', 'DE': 'Pestizid'},
    ),
    ItemType(
      id: 'herbicide',
      category: ItemCategory.garden,
      defaultUnit: 'liters',
      translations: {'EN': 'Herbicide', 'PT': 'Herbicida', 'ES': 'Herbicida', 'FR': 'Herbicide', 'DE': 'Herbizid'},
    ),
    ItemType(
      id: 'plant_pots',
      category: ItemCategory.garden,
      defaultUnit: 'units',
      translations: {'EN': 'Plant Pots', 'PT': 'Vasos', 'ES': 'Macetas', 'FR': 'Pots de Fleurs', 'DE': 'Blumentöpfe'},
    ),
    ItemType(
      id: 'garden_hose',
      category: ItemCategory.garden,
      defaultUnit: 'meters',
      translations: {'EN': 'Garden Hose', 'PT': 'Mangueira de Jardim', 'ES': 'Manguera de Jardín', 'FR': 'Tuyau d\'Arrosage', 'DE': 'Gartenschlauch'},
    ),
    ItemType(
      id: 'sprinkler',
      category: ItemCategory.garden,
      defaultUnit: 'units',
      translations: {'EN': 'Sprinkler', 'PT': 'Aspersor', 'ES': 'Aspersor', 'FR': 'Arroseur', 'DE': 'Rasensprenger'},
    ),
    ItemType(
      id: 'garden_gloves',
      category: ItemCategory.garden,
      defaultUnit: 'pairs',
      translations: {'EN': 'Garden Gloves', 'PT': 'Luvas de Jardim', 'ES': 'Guantes de Jardín', 'FR': 'Gants de Jardinage', 'DE': 'Gartenhandschuhe'},
    ),
    ItemType(
      id: 'pruning_shears',
      category: ItemCategory.garden,
      defaultUnit: 'units',
      translations: {'EN': 'Pruning Shears', 'PT': 'Tesoura de Poda', 'ES': 'Tijeras de Podar', 'FR': 'Sécateur', 'DE': 'Gartenschere'},
    ),
    ItemType(
      id: 'rake',
      category: ItemCategory.garden,
      defaultUnit: 'units',
      translations: {'EN': 'Rake', 'PT': 'Ancinho', 'ES': 'Rastrillo', 'FR': 'Râteau', 'DE': 'Rechen'},
    ),
    ItemType(
      id: 'shovel',
      category: ItemCategory.garden,
      defaultUnit: 'units',
      translations: {'EN': 'Shovel', 'PT': 'Pá', 'ES': 'Pala', 'FR': 'Pelle', 'DE': 'Schaufel'},
    ),
    ItemType(
      id: 'wheelbarrow',
      category: ItemCategory.garden,
      defaultUnit: 'units',
      translations: {'EN': 'Wheelbarrow', 'PT': 'Carrinho de Mão', 'ES': 'Carretilla', 'FR': 'Brouette', 'DE': 'Schubkarre'},
    ),
    ItemType(
      id: 'lawn_mower',
      category: ItemCategory.garden,
      defaultUnit: 'units',
      translations: {'EN': 'Lawn Mower', 'PT': 'Cortador de Relva', 'ES': 'Cortacésped', 'FR': 'Tondeuse', 'DE': 'Rasenmäher'},
    ),
  ];

  // Outdoor/Camping
  static const List<ItemType> outdoor = [
    ItemType(
      id: 'tent',
      category: ItemCategory.outdoor,
      defaultUnit: 'units',
      translations: {'EN': 'Tent', 'PT': 'Tenda', 'ES': 'Tienda', 'FR': 'Tente', 'DE': 'Zelt'},
    ),
    ItemType(
      id: 'sleeping_bag',
      category: ItemCategory.outdoor,
      defaultUnit: 'units',
      translations: {'EN': 'Sleeping Bag', 'PT': 'Saco-cama', 'ES': 'Saco de Dormir', 'FR': 'Sac de Couchage', 'DE': 'Schlafsack'},
    ),
    ItemType(
      id: 'sleeping_pad',
      category: ItemCategory.outdoor,
      defaultUnit: 'units',
      translations: {'EN': 'Sleeping Pad', 'PT': 'Colchão de Campismo', 'ES': 'Colchoneta', 'FR': 'Matelas de Sol', 'DE': 'Isomatte'},
    ),
    ItemType(
      id: 'camp_stove',
      category: ItemCategory.outdoor,
      defaultUnit: 'units',
      translations: {'EN': 'Camp Stove', 'PT': 'Fogão de Campismo', 'ES': 'Hornillo', 'FR': 'Réchaud', 'DE': 'Campingkocher'},
    ),
    ItemType(
      id: 'propane_tank',
      category: ItemCategory.outdoor,
      defaultUnit: 'units',
      translations: {'EN': 'Propane Tank', 'PT': 'Botija de Gás', 'ES': 'Bombona de Propano', 'FR': 'Bouteille de Propane', 'DE': 'Propanflasche'},
    ),
    ItemType(
      id: 'cooler',
      category: ItemCategory.outdoor,
      defaultUnit: 'units',
      translations: {'EN': 'Cooler', 'PT': 'Geleira', 'ES': 'Nevera', 'FR': 'Glacière', 'DE': 'Kühlbox'},
    ),
    ItemType(
      id: 'flashlight',
      category: ItemCategory.outdoor,
      defaultUnit: 'units',
      translations: {'EN': 'Flashlight', 'PT': 'Lanterna', 'ES': 'Linterna', 'FR': 'Lampe de Poche', 'DE': 'Taschenlampe'},
    ),
    ItemType(
      id: 'headlamp',
      category: ItemCategory.outdoor,
      defaultUnit: 'units',
      translations: {'EN': 'Headlamp', 'PT': 'Lanterna de Cabeça', 'ES': 'Linterna Frontal', 'FR': 'Lampe Frontale', 'DE': 'Stirnlampe'},
    ),
    ItemType(
      id: 'lantern',
      category: ItemCategory.outdoor,
      defaultUnit: 'units',
      translations: {'EN': 'Lantern', 'PT': 'Lampião', 'ES': 'Farol', 'FR': 'Lanterne', 'DE': 'Laterne'},
    ),
    ItemType(
      id: 'compass',
      category: ItemCategory.outdoor,
      defaultUnit: 'units',
      translations: {'EN': 'Compass', 'PT': 'Bússola', 'ES': 'Brújula', 'FR': 'Boussole', 'DE': 'Kompass'},
    ),
    ItemType(
      id: 'binoculars',
      category: ItemCategory.outdoor,
      defaultUnit: 'units',
      translations: {'EN': 'Binoculars', 'PT': 'Binóculos', 'ES': 'Prismáticos', 'FR': 'Jumelles', 'DE': 'Fernglas'},
    ),
    ItemType(
      id: 'multi_tool',
      category: ItemCategory.outdoor,
      defaultUnit: 'units',
      translations: {'EN': 'Multi-Tool', 'PT': 'Multiferramenta', 'ES': 'Multiherramienta', 'FR': 'Couteau Suisse', 'DE': 'Multifunktionswerkzeug'},
    ),
    ItemType(
      id: 'water_filter',
      category: ItemCategory.outdoor,
      defaultUnit: 'units',
      translations: {'EN': 'Water Filter', 'PT': 'Filtro de Água', 'ES': 'Filtro de Agua', 'FR': 'Filtre à Eau', 'DE': 'Wasserfilter'},
    ),
    ItemType(
      id: 'backpack',
      category: ItemCategory.outdoor,
      defaultUnit: 'units',
      translations: {'EN': 'Backpack', 'PT': 'Mochila', 'ES': 'Mochila', 'FR': 'Sac à Dos', 'DE': 'Rucksack'},
    ),
    ItemType(
      id: 'tarp',
      category: ItemCategory.outdoor,
      defaultUnit: 'units',
      translations: {'EN': 'Tarp', 'PT': 'Lona', 'ES': 'Lona', 'FR': 'Bâche', 'DE': 'Plane'},
    ),
    ItemType(
      id: 'paracord',
      category: ItemCategory.outdoor,
      defaultUnit: 'meters',
      translations: {'EN': 'Paracord', 'PT': 'Paracord', 'ES': 'Paracord', 'FR': 'Paracorde', 'DE': 'Paracord'},
    ),
    ItemType(
      id: 'fire_starter',
      category: ItemCategory.outdoor,
      defaultUnit: 'units',
      translations: {'EN': 'Fire Starter', 'PT': 'Acendedor de Fogo', 'ES': 'Iniciador de Fuego', 'FR': 'Allume-feu', 'DE': 'Feuerstarter'},
    ),
  ];

  // Electronics
  static const List<ItemType> electronics = [
    ItemType(
      id: 'usb_cable',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'USB Cable', 'PT': 'Cabo USB', 'ES': 'Cable USB', 'FR': 'Câble USB', 'DE': 'USB-Kabel'},
    ),
    ItemType(
      id: 'power_bank',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Power Bank', 'PT': 'Powerbank', 'ES': 'Batería Externa', 'FR': 'Batterie Externe', 'DE': 'Powerbank'},
    ),
    ItemType(
      id: 'charger',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Charger', 'PT': 'Carregador', 'ES': 'Cargador', 'FR': 'Chargeur', 'DE': 'Ladegerät'},
    ),
    ItemType(
      id: 'memory_card',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Memory Card', 'PT': 'Cartão de Memória', 'ES': 'Tarjeta de Memoria', 'FR': 'Carte Mémoire', 'DE': 'Speicherkarte'},
    ),
    ItemType(
      id: 'usb_drive',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'USB Drive', 'PT': 'Pen USB', 'ES': 'Memoria USB', 'FR': 'Clé USB', 'DE': 'USB-Stick'},
    ),
    ItemType(
      id: 'hard_drive',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Hard Drive', 'PT': 'Disco Rígido', 'ES': 'Disco Duro', 'FR': 'Disque Dur', 'DE': 'Festplatte'},
    ),
    ItemType(
      id: 'extension_cord',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Extension Cord', 'PT': 'Extensão', 'ES': 'Alargador', 'FR': 'Rallonge', 'DE': 'Verlängerungskabel'},
    ),
    ItemType(
      id: 'power_strip',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Power Strip', 'PT': 'Régua de Tomadas', 'ES': 'Regleta', 'FR': 'Multiprise', 'DE': 'Steckdosenleiste'},
    ),
    ItemType(
      id: 'hdmi_cable',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'HDMI Cable', 'PT': 'Cabo HDMI', 'ES': 'Cable HDMI', 'FR': 'Câble HDMI', 'DE': 'HDMI-Kabel'},
    ),
    ItemType(
      id: 'ethernet_cable',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Ethernet Cable', 'PT': 'Cabo Ethernet', 'ES': 'Cable Ethernet', 'FR': 'Câble Ethernet', 'DE': 'Ethernet-Kabel'},
    ),
    ItemType(
      id: 'soldering_iron',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Soldering Iron', 'PT': 'Ferro de Soldar', 'ES': 'Soldador', 'FR': 'Fer à Souder', 'DE': 'Lötkolben'},
    ),
    ItemType(
      id: 'solder',
      category: ItemCategory.electronics,
      defaultUnit: 'grams',
      translations: {'EN': 'Solder', 'PT': 'Solda', 'ES': 'Estaño', 'FR': 'Soudure', 'DE': 'Lötzinn'},
    ),
    ItemType(
      id: 'multimeter',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Multimeter', 'PT': 'Multímetro', 'ES': 'Multímetro', 'FR': 'Multimètre', 'DE': 'Multimeter'},
    ),
    ItemType(
      id: 'heat_shrink',
      category: ItemCategory.electronics,
      defaultUnit: 'meters',
      translations: {'EN': 'Heat Shrink', 'PT': 'Manga Termorretráctil', 'ES': 'Tubo Termoretráctil', 'FR': 'Gaine Thermorétractable', 'DE': 'Schrumpfschlauch'},
    ),
    // Solar & Wind Energy
    ItemType(
      id: 'solar_panel',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Solar Panel', 'PT': 'Painel Solar', 'ES': 'Panel Solar', 'FR': 'Panneau Solaire', 'DE': 'Solarpanel'},
    ),
    ItemType(
      id: 'solar_charger',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Solar Charger', 'PT': 'Carregador Solar', 'ES': 'Cargador Solar', 'FR': 'Chargeur Solaire', 'DE': 'Solarladegerät'},
    ),
    ItemType(
      id: 'solar_light',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Solar Light', 'PT': 'Luz Solar', 'ES': 'Luz Solar', 'FR': 'Lampe Solaire', 'DE': 'Solarlampe'},
    ),
    ItemType(
      id: 'solar_battery',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Solar Battery', 'PT': 'Bateria Solar', 'ES': 'Batería Solar', 'FR': 'Batterie Solaire', 'DE': 'Solarbatterie'},
    ),
    ItemType(
      id: 'solar_inverter',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Solar Inverter', 'PT': 'Inversor Solar', 'ES': 'Inversor Solar', 'FR': 'Onduleur Solaire', 'DE': 'Wechselrichter'},
    ),
    ItemType(
      id: 'solar_controller',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Solar Controller', 'PT': 'Controlador Solar', 'ES': 'Controlador Solar', 'FR': 'Régulateur Solaire', 'DE': 'Solarregler'},
    ),
    ItemType(
      id: 'wind_generator',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Wind Generator', 'PT': 'Gerador Eólico', 'ES': 'Generador Eólico', 'FR': 'Éolienne', 'DE': 'Windgenerator'},
    ),
    ItemType(
      id: 'wind_turbine',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Wind Turbine', 'PT': 'Turbina Eólica', 'ES': 'Turbina Eólica', 'FR': 'Turbine Éolienne', 'DE': 'Windturbine'},
    ),
    ItemType(
      id: 'generator',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Generator', 'PT': 'Gerador', 'ES': 'Generador', 'FR': 'Générateur', 'DE': 'Generator'},
    ),
    ItemType(
      id: 'inverter',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Inverter', 'PT': 'Inversor', 'ES': 'Inversor', 'FR': 'Onduleur', 'DE': 'Wechselrichter'},
    ),
    ItemType(
      id: 'ups',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'UPS', 'PT': 'UPS', 'ES': 'SAI', 'FR': 'Onduleur', 'DE': 'USV'},
    ),
    // Communication & Entertainment
    ItemType(
      id: 'radio',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Radio', 'PT': 'Rádio', 'ES': 'Radio', 'FR': 'Radio', 'DE': 'Radio'},
    ),
    ItemType(
      id: 'walkie_talkie',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Walkie-Talkie', 'PT': 'Walkie-Talkie', 'ES': 'Walkie-Talkie', 'FR': 'Talkie-Walkie', 'DE': 'Funkgerät'},
    ),
    ItemType(
      id: 'two_way_radio',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Two-Way Radio', 'PT': 'Rádio Bidirecional', 'ES': 'Radio Bidireccional', 'FR': 'Radio Bidirectionnelle', 'DE': 'Funkgerät'},
    ),
    ItemType(
      id: 'cb_radio',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'CB Radio', 'PT': 'Rádio CB', 'ES': 'Radio CB', 'FR': 'Radio CB', 'DE': 'CB-Funk'},
    ),
    ItemType(
      id: 'ham_radio',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Ham Radio', 'PT': 'Rádio Amador', 'ES': 'Radio Aficionado', 'FR': 'Radio Amateur', 'DE': 'Amateurfunk'},
    ),
    ItemType(
      id: 'antenna',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Antenna', 'PT': 'Antena', 'ES': 'Antena', 'FR': 'Antenne', 'DE': 'Antenne'},
    ),
    ItemType(
      id: 'television',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Television', 'PT': 'Televisão', 'ES': 'Televisión', 'FR': 'Télévision', 'DE': 'Fernseher'},
    ),
    ItemType(
      id: 'monitor',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Monitor', 'PT': 'Monitor', 'ES': 'Monitor', 'FR': 'Moniteur', 'DE': 'Monitor'},
    ),
    ItemType(
      id: 'laptop',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Laptop', 'PT': 'Portátil', 'ES': 'Portátil', 'FR': 'Ordinateur Portable', 'DE': 'Laptop'},
    ),
    ItemType(
      id: 'desktop_computer',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Desktop Computer', 'PT': 'Computador de Secretária', 'ES': 'Ordenador de Sobremesa', 'FR': 'Ordinateur de Bureau', 'DE': 'Desktop-Computer'},
    ),
    ItemType(
      id: 'tablet',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Tablet', 'PT': 'Tablet', 'ES': 'Tableta', 'FR': 'Tablette', 'DE': 'Tablet'},
    ),
    ItemType(
      id: 'smartphone',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Smartphone', 'PT': 'Smartphone', 'ES': 'Smartphone', 'FR': 'Smartphone', 'DE': 'Smartphone'},
    ),
    ItemType(
      id: 'keyboard',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Keyboard', 'PT': 'Teclado', 'ES': 'Teclado', 'FR': 'Clavier', 'DE': 'Tastatur'},
    ),
    ItemType(
      id: 'mouse',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Mouse', 'PT': 'Rato', 'ES': 'Ratón', 'FR': 'Souris', 'DE': 'Maus'},
    ),
    ItemType(
      id: 'printer',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Printer', 'PT': 'Impressora', 'ES': 'Impresora', 'FR': 'Imprimante', 'DE': 'Drucker'},
    ),
    ItemType(
      id: 'scanner',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Scanner', 'PT': 'Scanner', 'ES': 'Escáner', 'FR': 'Scanner', 'DE': 'Scanner'},
    ),
    ItemType(
      id: 'projector',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Projector', 'PT': 'Projetor', 'ES': 'Proyector', 'FR': 'Projecteur', 'DE': 'Beamer'},
    ),
    ItemType(
      id: 'speakers',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Speakers', 'PT': 'Colunas', 'ES': 'Altavoces', 'FR': 'Haut-parleurs', 'DE': 'Lautsprecher'},
    ),
    ItemType(
      id: 'headphones',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Headphones', 'PT': 'Auscultadores', 'ES': 'Auriculares', 'FR': 'Casque', 'DE': 'Kopfhörer'},
    ),
    ItemType(
      id: 'microphone',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Microphone', 'PT': 'Microfone', 'ES': 'Micrófono', 'FR': 'Microphone', 'DE': 'Mikrofon'},
    ),
    ItemType(
      id: 'webcam',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Webcam', 'PT': 'Webcam', 'ES': 'Webcam', 'FR': 'Webcam', 'DE': 'Webcam'},
    ),
    ItemType(
      id: 'router',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Router', 'PT': 'Router', 'ES': 'Router', 'FR': 'Routeur', 'DE': 'Router'},
    ),
    ItemType(
      id: 'modem',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Modem', 'PT': 'Modem', 'ES': 'Módem', 'FR': 'Modem', 'DE': 'Modem'},
    ),
    ItemType(
      id: 'game_console',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Game Console', 'PT': 'Consola de Jogos', 'ES': 'Consola de Videojuegos', 'FR': 'Console de Jeu', 'DE': 'Spielkonsole'},
    ),
    ItemType(
      id: 'drone',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Drone', 'PT': 'Drone', 'ES': 'Dron', 'FR': 'Drone', 'DE': 'Drohne'},
    ),
    ItemType(
      id: 'action_camera',
      category: ItemCategory.electronics,
      defaultUnit: 'units',
      translations: {'EN': 'Action Camera', 'PT': 'Câmara de Ação', 'ES': 'Cámara de Acción', 'FR': 'Caméra d\'Action', 'DE': 'Actionkamera'},
    ),
  ];

  // Office
  static const List<ItemType> office = [
    ItemType(
      id: 'paper',
      category: ItemCategory.office,
      defaultUnit: 'sheets',
      translations: {'EN': 'Paper', 'PT': 'Papel', 'ES': 'Papel', 'FR': 'Papier', 'DE': 'Papier'},
    ),
    ItemType(
      id: 'pens',
      category: ItemCategory.office,
      defaultUnit: 'units',
      translations: {'EN': 'Pens', 'PT': 'Canetas', 'ES': 'Bolígrafos', 'FR': 'Stylos', 'DE': 'Kugelschreiber'},
    ),
    ItemType(
      id: 'pencils',
      category: ItemCategory.office,
      defaultUnit: 'units',
      translations: {'EN': 'Pencils', 'PT': 'Lápis', 'ES': 'Lápices', 'FR': 'Crayons', 'DE': 'Bleistifte'},
    ),
    ItemType(
      id: 'markers',
      category: ItemCategory.office,
      defaultUnit: 'units',
      translations: {'EN': 'Markers', 'PT': 'Marcadores', 'ES': 'Rotuladores', 'FR': 'Marqueurs', 'DE': 'Marker'},
    ),
    ItemType(
      id: 'highlighters',
      category: ItemCategory.office,
      defaultUnit: 'units',
      translations: {'EN': 'Highlighters', 'PT': 'Marcadores Fluorescentes', 'ES': 'Subrayadores', 'FR': 'Surligneurs', 'DE': 'Textmarker'},
    ),
    ItemType(
      id: 'notebooks',
      category: ItemCategory.office,
      defaultUnit: 'units',
      translations: {'EN': 'Notebooks', 'PT': 'Cadernos', 'ES': 'Cuadernos', 'FR': 'Cahiers', 'DE': 'Notizbücher'},
    ),
    ItemType(
      id: 'folders',
      category: ItemCategory.office,
      defaultUnit: 'units',
      translations: {'EN': 'Folders', 'PT': 'Pastas', 'ES': 'Carpetas', 'FR': 'Dossiers', 'DE': 'Ordner'},
    ),
    ItemType(
      id: 'binders',
      category: ItemCategory.office,
      defaultUnit: 'units',
      translations: {'EN': 'Binders', 'PT': 'Arquivadores', 'ES': 'Archivadores', 'FR': 'Classeurs', 'DE': 'Aktenordner'},
    ),
    ItemType(
      id: 'stapler',
      category: ItemCategory.office,
      defaultUnit: 'units',
      translations: {'EN': 'Stapler', 'PT': 'Agrafador', 'ES': 'Grapadora', 'FR': 'Agrafeuse', 'DE': 'Hefter'},
    ),
    ItemType(
      id: 'staples',
      category: ItemCategory.office,
      defaultUnit: 'boxes',
      translations: {'EN': 'Staples', 'PT': 'Agrafos', 'ES': 'Grapas', 'FR': 'Agrafes', 'DE': 'Heftklammern'},
    ),
    ItemType(
      id: 'paper_clips',
      category: ItemCategory.office,
      defaultUnit: 'boxes',
      translations: {'EN': 'Paper Clips', 'PT': 'Clipes', 'ES': 'Clips', 'FR': 'Trombones', 'DE': 'Büroklammern'},
    ),
    ItemType(
      id: 'rubber_bands',
      category: ItemCategory.office,
      defaultUnit: 'units',
      translations: {'EN': 'Rubber Bands', 'PT': 'Elásticos', 'ES': 'Gomas', 'FR': 'Élastiques', 'DE': 'Gummibänder'},
    ),
    ItemType(
      id: 'tape',
      category: ItemCategory.office,
      defaultUnit: 'rolls',
      translations: {'EN': 'Tape', 'PT': 'Fita-cola', 'ES': 'Cinta', 'FR': 'Ruban', 'DE': 'Klebeband'},
    ),
    ItemType(
      id: 'scissors',
      category: ItemCategory.office,
      defaultUnit: 'units',
      translations: {'EN': 'Scissors', 'PT': 'Tesoura', 'ES': 'Tijeras', 'FR': 'Ciseaux', 'DE': 'Schere'},
    ),
    ItemType(
      id: 'envelopes',
      category: ItemCategory.office,
      defaultUnit: 'units',
      translations: {'EN': 'Envelopes', 'PT': 'Envelopes', 'ES': 'Sobres', 'FR': 'Enveloppes', 'DE': 'Briefumschläge'},
    ),
    ItemType(
      id: 'labels',
      category: ItemCategory.office,
      defaultUnit: 'sheets',
      translations: {'EN': 'Labels', 'PT': 'Etiquetas', 'ES': 'Etiquetas', 'FR': 'Étiquettes', 'DE': 'Etiketten'},
    ),
    ItemType(
      id: 'sticky_notes',
      category: ItemCategory.office,
      defaultUnit: 'packs',
      translations: {'EN': 'Sticky Notes', 'PT': 'Post-its', 'ES': 'Notas Adhesivas', 'FR': 'Post-it', 'DE': 'Haftnotizen'},
    ),
    ItemType(
      id: 'correction_fluid',
      category: ItemCategory.office,
      defaultUnit: 'units',
      translations: {'EN': 'Correction Fluid', 'PT': 'Corrector', 'ES': 'Líquido Corrector', 'FR': 'Correcteur', 'DE': 'Korrekturflüssigkeit'},
    ),
    ItemType(
      id: 'printer_ink',
      category: ItemCategory.office,
      defaultUnit: 'units',
      translations: {'EN': 'Printer Ink', 'PT': 'Tinta de Impressora', 'ES': 'Tinta de Impresora', 'FR': 'Encre d\'Imprimante', 'DE': 'Druckertinte'},
    ),
    ItemType(
      id: 'toner',
      category: ItemCategory.office,
      defaultUnit: 'units',
      translations: {'EN': 'Toner', 'PT': 'Toner', 'ES': 'Tóner', 'FR': 'Toner', 'DE': 'Toner'},
    ),
  ];

  // Safety equipment
  static const List<ItemType> safety = [
    ItemType(
      id: 'fire_extinguisher',
      category: ItemCategory.safety,
      defaultUnit: 'units',
      translations: {'EN': 'Fire Extinguisher', 'PT': 'Extintor', 'ES': 'Extintor', 'FR': 'Extincteur', 'DE': 'Feuerlöscher'},
    ),
    ItemType(
      id: 'smoke_detector',
      category: ItemCategory.safety,
      defaultUnit: 'units',
      translations: {'EN': 'Smoke Detector', 'PT': 'Detetor de Fumo', 'ES': 'Detector de Humo', 'FR': 'Détecteur de Fumée', 'DE': 'Rauchmelder'},
    ),
    ItemType(
      id: 'carbon_monoxide_detector',
      category: ItemCategory.safety,
      defaultUnit: 'units',
      translations: {'EN': 'Carbon Monoxide Detector', 'PT': 'Detetor de Monóxido de Carbono', 'ES': 'Detector de Monóxido de Carbono', 'FR': 'Détecteur de Monoxyde de Carbone', 'DE': 'Kohlenmonoxidmelder'},
    ),
    ItemType(
      id: 'safety_glasses',
      category: ItemCategory.safety,
      defaultUnit: 'units',
      translations: {'EN': 'Safety Glasses', 'PT': 'Óculos de Proteção', 'ES': 'Gafas de Seguridad', 'FR': 'Lunettes de Protection', 'DE': 'Schutzbrille'},
    ),
    ItemType(
      id: 'ear_protection',
      category: ItemCategory.safety,
      defaultUnit: 'units',
      translations: {'EN': 'Ear Protection', 'PT': 'Protetores Auriculares', 'ES': 'Protección Auditiva', 'FR': 'Protection Auditive', 'DE': 'Gehörschutz'},
    ),
    ItemType(
      id: 'work_gloves',
      category: ItemCategory.safety,
      defaultUnit: 'pairs',
      translations: {'EN': 'Work Gloves', 'PT': 'Luvas de Trabalho', 'ES': 'Guantes de Trabajo', 'FR': 'Gants de Travail', 'DE': 'Arbeitshandschuhe'},
    ),
    ItemType(
      id: 'hard_hat',
      category: ItemCategory.safety,
      defaultUnit: 'units',
      translations: {'EN': 'Hard Hat', 'PT': 'Capacete de Segurança', 'ES': 'Casco de Seguridad', 'FR': 'Casque de Chantier', 'DE': 'Schutzhelm'},
    ),
    ItemType(
      id: 'safety_vest',
      category: ItemCategory.safety,
      defaultUnit: 'units',
      translations: {'EN': 'Safety Vest', 'PT': 'Colete Refletor', 'ES': 'Chaleco de Seguridad', 'FR': 'Gilet de Sécurité', 'DE': 'Warnweste'},
    ),
    ItemType(
      id: 'dust_mask',
      category: ItemCategory.safety,
      defaultUnit: 'units',
      translations: {'EN': 'Dust Mask', 'PT': 'Máscara de Pó', 'ES': 'Mascarilla de Polvo', 'FR': 'Masque Anti-poussière', 'DE': 'Staubmaske'},
    ),
    ItemType(
      id: 'respirator',
      category: ItemCategory.safety,
      defaultUnit: 'units',
      translations: {'EN': 'Respirator', 'PT': 'Respirador', 'ES': 'Respirador', 'FR': 'Respirateur', 'DE': 'Atemschutz'},
    ),
  ];

  // Kitchen
  static const List<ItemType> kitchen = [
    ItemType(
      id: 'plate',
      category: ItemCategory.kitchen,
      defaultUnit: 'units',
      translations: {'EN': 'Plate', 'PT': 'Prato', 'ES': 'Plato', 'FR': 'Assiette', 'DE': 'Teller'},
    ),
    ItemType(
      id: 'bowl',
      category: ItemCategory.kitchen,
      defaultUnit: 'units',
      translations: {'EN': 'Bowl', 'PT': 'Tigela', 'ES': 'Cuenco', 'FR': 'Bol', 'DE': 'Schüssel'},
    ),
    ItemType(
      id: 'glass',
      category: ItemCategory.kitchen,
      defaultUnit: 'units',
      translations: {'EN': 'Glass', 'PT': 'Copo', 'ES': 'Vaso', 'FR': 'Verre', 'DE': 'Glas'},
    ),
    ItemType(
      id: 'cup',
      category: ItemCategory.kitchen,
      defaultUnit: 'units',
      translations: {'EN': 'Cup', 'PT': 'Chávena', 'ES': 'Taza', 'FR': 'Tasse', 'DE': 'Tasse'},
    ),
    ItemType(
      id: 'mug',
      category: ItemCategory.kitchen,
      defaultUnit: 'units',
      translations: {'EN': 'Mug', 'PT': 'Caneca', 'ES': 'Tazón', 'FR': 'Mug', 'DE': 'Becher'},
    ),
    ItemType(
      id: 'pot',
      category: ItemCategory.kitchen,
      defaultUnit: 'units',
      translations: {'EN': 'Pot', 'PT': 'Panela', 'ES': 'Olla', 'FR': 'Casserole', 'DE': 'Topf'},
    ),
    ItemType(
      id: 'pan',
      category: ItemCategory.kitchen,
      defaultUnit: 'units',
      translations: {'EN': 'Pan', 'PT': 'Frigideira', 'ES': 'Sartén', 'FR': 'Poêle', 'DE': 'Pfanne'},
    ),
    ItemType(
      id: 'frying_pan',
      category: ItemCategory.kitchen,
      defaultUnit: 'units',
      translations: {'EN': 'Frying Pan', 'PT': 'Frigideira', 'ES': 'Sartén', 'FR': 'Poêle à frire', 'DE': 'Bratpfanne'},
    ),
    ItemType(
      id: 'kettle',
      category: ItemCategory.kitchen,
      defaultUnit: 'units',
      translations: {'EN': 'Kettle', 'PT': 'Chaleira', 'ES': 'Hervidor', 'FR': 'Bouilloire', 'DE': 'Wasserkocher'},
    ),
    ItemType(
      id: 'kitchen_knife',
      category: ItemCategory.kitchen,
      defaultUnit: 'units',
      translations: {'EN': 'Kitchen Knife', 'PT': 'Faca de Cozinha', 'ES': 'Cuchillo de Cocina', 'FR': 'Couteau de Cuisine', 'DE': 'Küchenmesser'},
    ),
    ItemType(
      id: 'cutting_board',
      category: ItemCategory.kitchen,
      defaultUnit: 'units',
      translations: {'EN': 'Cutting Board', 'PT': 'Tábua de Cortar', 'ES': 'Tabla de Cortar', 'FR': 'Planche à Découper', 'DE': 'Schneidebrett'},
    ),
    ItemType(
      id: 'fork',
      category: ItemCategory.kitchen,
      defaultUnit: 'units',
      translations: {'EN': 'Fork', 'PT': 'Garfo', 'ES': 'Tenedor', 'FR': 'Fourchette', 'DE': 'Gabel'},
    ),
    ItemType(
      id: 'spoon',
      category: ItemCategory.kitchen,
      defaultUnit: 'units',
      translations: {'EN': 'Spoon', 'PT': 'Colher', 'ES': 'Cuchara', 'FR': 'Cuillère', 'DE': 'Löffel'},
    ),
    ItemType(
      id: 'spatula',
      category: ItemCategory.kitchen,
      defaultUnit: 'units',
      translations: {'EN': 'Spatula', 'PT': 'Espátula', 'ES': 'Espátula', 'FR': 'Spatule', 'DE': 'Pfannenwender'},
    ),
    ItemType(
      id: 'ladle',
      category: ItemCategory.kitchen,
      defaultUnit: 'units',
      translations: {'EN': 'Ladle', 'PT': 'Concha', 'ES': 'Cucharón', 'FR': 'Louche', 'DE': 'Schöpfkelle'},
    ),
    ItemType(
      id: 'strainer',
      category: ItemCategory.kitchen,
      defaultUnit: 'units',
      translations: {'EN': 'Strainer', 'PT': 'Coador', 'ES': 'Colador', 'FR': 'Passoire', 'DE': 'Sieb'},
    ),
    ItemType(
      id: 'can_opener',
      category: ItemCategory.kitchen,
      defaultUnit: 'units',
      translations: {'EN': 'Can Opener', 'PT': 'Abre-latas', 'ES': 'Abrelatas', 'FR': 'Ouvre-boîte', 'DE': 'Dosenöffner'},
    ),
    ItemType(
      id: 'bottle_opener',
      category: ItemCategory.kitchen,
      defaultUnit: 'units',
      translations: {'EN': 'Bottle Opener', 'PT': 'Abre-garrafas', 'ES': 'Abridor', 'FR': 'Décapsuleur', 'DE': 'Flaschenöffner'},
    ),
    ItemType(
      id: 'corkscrew',
      category: ItemCategory.kitchen,
      defaultUnit: 'units',
      translations: {'EN': 'Corkscrew', 'PT': 'Saca-rolhas', 'ES': 'Sacacorchos', 'FR': 'Tire-bouchon', 'DE': 'Korkenzieher'},
    ),
    ItemType(
      id: 'thermos',
      category: ItemCategory.kitchen,
      defaultUnit: 'units',
      translations: {'EN': 'Thermos', 'PT': 'Termo', 'ES': 'Termo', 'FR': 'Thermos', 'DE': 'Thermoskanne'},
    ),
    ItemType(
      id: 'water_bottle',
      category: ItemCategory.kitchen,
      defaultUnit: 'units',
      translations: {'EN': 'Water Bottle', 'PT': 'Garrafa de Água', 'ES': 'Botella de Agua', 'FR': 'Bouteille d\'eau', 'DE': 'Wasserflasche'},
    ),
  ];

  // Furniture
  static const List<ItemType> furniture = [
    ItemType(
      id: 'bed',
      category: ItemCategory.furniture,
      defaultUnit: 'units',
      translations: {'EN': 'Bed', 'PT': 'Cama', 'ES': 'Cama', 'FR': 'Lit', 'DE': 'Bett'},
    ),
    ItemType(
      id: 'mattress',
      category: ItemCategory.furniture,
      defaultUnit: 'units',
      translations: {'EN': 'Mattress', 'PT': 'Colchão', 'ES': 'Colchón', 'FR': 'Matelas', 'DE': 'Matratze'},
    ),
    ItemType(
      id: 'pillow',
      category: ItemCategory.furniture,
      defaultUnit: 'units',
      translations: {'EN': 'Pillow', 'PT': 'Almofada', 'ES': 'Almohada', 'FR': 'Oreiller', 'DE': 'Kissen'},
    ),
    ItemType(
      id: 'blanket',
      category: ItemCategory.furniture,
      defaultUnit: 'units',
      translations: {'EN': 'Blanket', 'PT': 'Cobertor', 'ES': 'Manta', 'FR': 'Couverture', 'DE': 'Decke'},
    ),
    ItemType(
      id: 'sheets',
      category: ItemCategory.furniture,
      defaultUnit: 'sets',
      translations: {'EN': 'Bed Sheets', 'PT': 'Lençóis', 'ES': 'Sábanas', 'FR': 'Draps', 'DE': 'Bettwäsche'},
    ),
    ItemType(
      id: 'chair',
      category: ItemCategory.furniture,
      defaultUnit: 'units',
      translations: {'EN': 'Chair', 'PT': 'Cadeira', 'ES': 'Silla', 'FR': 'Chaise', 'DE': 'Stuhl'},
    ),
    ItemType(
      id: 'table',
      category: ItemCategory.furniture,
      defaultUnit: 'units',
      translations: {'EN': 'Table', 'PT': 'Mesa', 'ES': 'Mesa', 'FR': 'Table', 'DE': 'Tisch'},
    ),
    ItemType(
      id: 'desk',
      category: ItemCategory.furniture,
      defaultUnit: 'units',
      translations: {'EN': 'Desk', 'PT': 'Secretária', 'ES': 'Escritorio', 'FR': 'Bureau', 'DE': 'Schreibtisch'},
    ),
    ItemType(
      id: 'sofa',
      category: ItemCategory.furniture,
      defaultUnit: 'units',
      translations: {'EN': 'Sofa', 'PT': 'Sofá', 'ES': 'Sofá', 'FR': 'Canapé', 'DE': 'Sofa'},
    ),
    ItemType(
      id: 'armchair',
      category: ItemCategory.furniture,
      defaultUnit: 'units',
      translations: {'EN': 'Armchair', 'PT': 'Poltrona', 'ES': 'Sillón', 'FR': 'Fauteuil', 'DE': 'Sessel'},
    ),
    ItemType(
      id: 'wardrobe',
      category: ItemCategory.furniture,
      defaultUnit: 'units',
      translations: {'EN': 'Wardrobe', 'PT': 'Guarda-roupa', 'ES': 'Armario', 'FR': 'Armoire', 'DE': 'Kleiderschrank'},
    ),
    ItemType(
      id: 'dresser',
      category: ItemCategory.furniture,
      defaultUnit: 'units',
      translations: {'EN': 'Dresser', 'PT': 'Cómoda', 'ES': 'Cómoda', 'FR': 'Commode', 'DE': 'Kommode'},
    ),
    ItemType(
      id: 'bookshelf',
      category: ItemCategory.furniture,
      defaultUnit: 'units',
      translations: {'EN': 'Bookshelf', 'PT': 'Estante', 'ES': 'Estantería', 'FR': 'Étagère', 'DE': 'Bücherregal'},
    ),
    ItemType(
      id: 'nightstand',
      category: ItemCategory.furniture,
      defaultUnit: 'units',
      translations: {'EN': 'Nightstand', 'PT': 'Mesa de Cabeceira', 'ES': 'Mesita de Noche', 'FR': 'Table de Chevet', 'DE': 'Nachttisch'},
    ),
    ItemType(
      id: 'mirror',
      category: ItemCategory.furniture,
      defaultUnit: 'units',
      translations: {'EN': 'Mirror', 'PT': 'Espelho', 'ES': 'Espejo', 'FR': 'Miroir', 'DE': 'Spiegel'},
    ),
    ItemType(
      id: 'lamp',
      category: ItemCategory.furniture,
      defaultUnit: 'units',
      translations: {'EN': 'Lamp', 'PT': 'Candeeiro', 'ES': 'Lámpara', 'FR': 'Lampe', 'DE': 'Lampe'},
    ),
    ItemType(
      id: 'rug',
      category: ItemCategory.furniture,
      defaultUnit: 'units',
      translations: {'EN': 'Rug', 'PT': 'Tapete', 'ES': 'Alfombra', 'FR': 'Tapis', 'DE': 'Teppich'},
    ),
    ItemType(
      id: 'curtains',
      category: ItemCategory.furniture,
      defaultUnit: 'pairs',
      translations: {'EN': 'Curtains', 'PT': 'Cortinas', 'ES': 'Cortinas', 'FR': 'Rideaux', 'DE': 'Vorhänge'},
    ),
  ];

  // Storage
  static const List<ItemType> storage = [
    ItemType(
      id: 'box',
      category: ItemCategory.storage,
      defaultUnit: 'units',
      translations: {'EN': 'Box', 'PT': 'Caixa', 'ES': 'Caja', 'FR': 'Boîte', 'DE': 'Karton'},
    ),
    ItemType(
      id: 'storage_box',
      category: ItemCategory.storage,
      defaultUnit: 'units',
      translations: {'EN': 'Storage Box', 'PT': 'Caixa de Arrumação', 'ES': 'Caja de Almacenamiento', 'FR': 'Boîte de Rangement', 'DE': 'Aufbewahrungsbox'},
    ),
    ItemType(
      id: 'plastic_container',
      category: ItemCategory.storage,
      defaultUnit: 'units',
      translations: {'EN': 'Plastic Container', 'PT': 'Recipiente de Plástico', 'ES': 'Contenedor de Plástico', 'FR': 'Boîte Plastique', 'DE': 'Plastikbehälter'},
    ),
    ItemType(
      id: 'crate',
      category: ItemCategory.storage,
      defaultUnit: 'units',
      translations: {'EN': 'Crate', 'PT': 'Caixote', 'ES': 'Cajón', 'FR': 'Caisse', 'DE': 'Kiste'},
    ),
    ItemType(
      id: 'bin',
      category: ItemCategory.storage,
      defaultUnit: 'units',
      translations: {'EN': 'Bin', 'PT': 'Contentor', 'ES': 'Contenedor', 'FR': 'Bac', 'DE': 'Behälter'},
    ),
    ItemType(
      id: 'basket',
      category: ItemCategory.storage,
      defaultUnit: 'units',
      translations: {'EN': 'Basket', 'PT': 'Cesto', 'ES': 'Cesta', 'FR': 'Panier', 'DE': 'Korb'},
    ),
    ItemType(
      id: 'shelf',
      category: ItemCategory.storage,
      defaultUnit: 'units',
      translations: {'EN': 'Shelf', 'PT': 'Prateleira', 'ES': 'Estante', 'FR': 'Étagère', 'DE': 'Regal'},
    ),
    ItemType(
      id: 'drawer_organizer',
      category: ItemCategory.storage,
      defaultUnit: 'units',
      translations: {'EN': 'Drawer Organizer', 'PT': 'Organizador de Gaveta', 'ES': 'Organizador de Cajón', 'FR': 'Organisateur de Tiroir', 'DE': 'Schubladenorganizer'},
    ),
    ItemType(
      id: 'toolbox',
      category: ItemCategory.storage,
      defaultUnit: 'units',
      translations: {'EN': 'Toolbox', 'PT': 'Caixa de Ferramentas', 'ES': 'Caja de Herramientas', 'FR': 'Boîte à Outils', 'DE': 'Werkzeugkasten'},
    ),
    ItemType(
      id: 'trunk',
      category: ItemCategory.storage,
      defaultUnit: 'units',
      translations: {'EN': 'Trunk', 'PT': 'Baú', 'ES': 'Baúl', 'FR': 'Malle', 'DE': 'Truhe'},
    ),
    ItemType(
      id: 'suitcase',
      category: ItemCategory.storage,
      defaultUnit: 'units',
      translations: {'EN': 'Suitcase', 'PT': 'Mala', 'ES': 'Maleta', 'FR': 'Valise', 'DE': 'Koffer'},
    ),
    ItemType(
      id: 'backpack',
      category: ItemCategory.storage,
      defaultUnit: 'units',
      translations: {'EN': 'Backpack', 'PT': 'Mochila', 'ES': 'Mochila', 'FR': 'Sac à Dos', 'DE': 'Rucksack'},
    ),
    ItemType(
      id: 'bag',
      category: ItemCategory.storage,
      defaultUnit: 'units',
      translations: {'EN': 'Bag', 'PT': 'Saco', 'ES': 'Bolsa', 'FR': 'Sac', 'DE': 'Tasche'},
    ),
  ];

  // Other
  static const List<ItemType> other = [
    ItemType(
      id: 'other',
      category: ItemCategory.other,
      defaultUnit: 'units',
      translations: {'EN': 'Other', 'PT': 'Outro', 'ES': 'Otro', 'FR': 'Autre', 'DE': 'Andere'},
    ),
    ItemType(
      id: 'custom',
      category: ItemCategory.other,
      defaultUnit: 'units',
      translations: {'EN': 'Custom Item', 'PT': 'Item Personalizado', 'ES': 'Artículo Personalizado', 'FR': 'Article Personnalisé', 'DE': 'Benutzerdefiniert'},
    ),
  ];

  /// All item types combined
  static List<ItemType> get all => [
        ...food,
        ...beverages,
        ...household,
        ...cleaning,
        ...medical,
        ...tools,
        ...automotive,
        ...garden,
        ...outdoor,
        ...electronics,
        ...office,
        ...safety,
        ...kitchen,
        ...furniture,
        ...storage,
        ...other,
      ];

  /// Get item types by category
  static List<ItemType> byCategory(ItemCategory category) {
    switch (category) {
      case ItemCategory.food:
        return food;
      case ItemCategory.beverages:
        return beverages;
      case ItemCategory.household:
        return household;
      case ItemCategory.cleaning:
        return cleaning;
      case ItemCategory.medical:
        return medical;
      case ItemCategory.tools:
        return tools;
      case ItemCategory.automotive:
        return automotive;
      case ItemCategory.garden:
        return garden;
      case ItemCategory.outdoor:
      case ItemCategory.camping:
        return outdoor;
      case ItemCategory.electronics:
        return electronics;
      case ItemCategory.office:
        return office;
      case ItemCategory.safety:
        return safety;
      case ItemCategory.kitchen:
        return kitchen;
      case ItemCategory.furniture:
        return furniture;
      case ItemCategory.storage:
        return storage;
      default:
        return other;
    }
  }

  /// Get an item type by ID
  static ItemType? getById(String id) {
    try {
      return all.firstWhere((t) => t.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Search item types by name
  static List<ItemType> search(String query, {String langCode = 'EN'}) {
    final q = query.toLowerCase();
    return all.where((t) {
      return t.id.toLowerCase().contains(q) ||
          t.getName(langCode).toLowerCase().contains(q);
    }).toList();
  }

  /// Get category name translation
  static String getCategoryName(ItemCategory category, String langCode) {
    final translations = {
      ItemCategory.food: {'EN': 'Food', 'PT': 'Alimentação', 'ES': 'Alimentación', 'FR': 'Alimentation', 'DE': 'Lebensmittel'},
      ItemCategory.beverages: {'EN': 'Beverages', 'PT': 'Bebidas', 'ES': 'Bebidas', 'FR': 'Boissons', 'DE': 'Getränke'},
      ItemCategory.household: {'EN': 'Household', 'PT': 'Casa', 'ES': 'Hogar', 'FR': 'Maison', 'DE': 'Haushalt'},
      ItemCategory.cleaning: {'EN': 'Cleaning', 'PT': 'Limpeza', 'ES': 'Limpieza', 'FR': 'Nettoyage', 'DE': 'Reinigung'},
      ItemCategory.medical: {'EN': 'Medical', 'PT': 'Médico', 'ES': 'Médico', 'FR': 'Médical', 'DE': 'Medizin'},
      ItemCategory.tools: {'EN': 'Tools', 'PT': 'Ferramentas', 'ES': 'Herramientas', 'FR': 'Outils', 'DE': 'Werkzeuge'},
      ItemCategory.automotive: {'EN': 'Automotive', 'PT': 'Automóvel', 'ES': 'Automóvil', 'FR': 'Automobile', 'DE': 'Auto'},
      ItemCategory.garden: {'EN': 'Garden', 'PT': 'Jardim', 'ES': 'Jardín', 'FR': 'Jardin', 'DE': 'Garten'},
      ItemCategory.outdoor: {'EN': 'Outdoor', 'PT': 'Ar Livre', 'ES': 'Exterior', 'FR': 'Plein Air', 'DE': 'Outdoor'},
      ItemCategory.electronics: {'EN': 'Electronics', 'PT': 'Eletrónica', 'ES': 'Electrónica', 'FR': 'Électronique', 'DE': 'Elektronik'},
      ItemCategory.office: {'EN': 'Office', 'PT': 'Escritório', 'ES': 'Oficina', 'FR': 'Bureau', 'DE': 'Büro'},
      ItemCategory.safety: {'EN': 'Safety', 'PT': 'Segurança', 'ES': 'Seguridad', 'FR': 'Sécurité', 'DE': 'Sicherheit'},
      ItemCategory.kitchen: {'EN': 'Kitchen', 'PT': 'Cozinha', 'ES': 'Cocina', 'FR': 'Cuisine', 'DE': 'Küche'},
      ItemCategory.furniture: {'EN': 'Furniture', 'PT': 'Mobiliário', 'ES': 'Muebles', 'FR': 'Meubles', 'DE': 'Möbel'},
      ItemCategory.storage: {'EN': 'Storage', 'PT': 'Arrumação', 'ES': 'Almacenamiento', 'FR': 'Rangement', 'DE': 'Aufbewahrung'},
      ItemCategory.other: {'EN': 'Other', 'PT': 'Outro', 'ES': 'Otro', 'FR': 'Autre', 'DE': 'Andere'},
    };
    return translations[category]?[langCode] ?? category.name;
  }
}
