/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Predefined service types for the Services app
///
/// Each type has a key (lowercase with hyphens) and translations.
/// Types are organized by category for UI grouping.
class ServiceTypes {
  ServiceTypes._();

  /// All service types organized by category
  static const Map<String, List<String>> categorizedTypes = {
    'home_property': [
      'plumber',
      'electrician',
      'carpenter',
      'painter',
      'roofer',
      'gardener',
      'cleaner',
      'handyman',
      'locksmith',
      'pest-control',
      'hvac',
      'mover',
    ],
    'automotive': [
      'mechanic',
      'auto-electrician',
      'tow-service',
      'car-wash',
      'tire-service',
      'auto-body',
    ],
    'personal': [
      'tutor',
      'nurse',
      'caregiver',
      'personal-trainer',
      'massage-therapist',
      'hairdresser',
      'barber',
      'beautician',
      'tailor',
      'chef',
    ],
    'professional': [
      'lawyer',
      'accountant',
      'notary',
      'translator',
      'photographer',
      'videographer',
      'graphic-designer',
      'web-developer',
    ],
    'technical': [
      'it-support',
      'appliance-repair',
      'phone-repair',
      'computer-repair',
      'solar-installer',
      'security-systems',
    ],
    'events': [
      'dj',
      'musician',
      'event-planner',
      'caterer',
    ],
    'pets': [
      'veterinarian',
      'pet-groomer',
      'pet-sitter',
      'dog-walker',
    ],
  };

  /// Get all service types as a flat list
  static List<String> get allTypes {
    final types = <String>[];
    for (final category in categorizedTypes.values) {
      types.addAll(category);
    }
    return types;
  }

  /// Check if a type is valid
  static bool isValidType(String type) {
    return allTypes.contains(type);
  }

  /// Get category for a type
  static String? getCategoryForType(String type) {
    for (final entry in categorizedTypes.entries) {
      if (entry.value.contains(type)) {
        return entry.key;
      }
    }
    return null;
  }

  /// Get types for a category
  static List<String> getTypesForCategory(String category) {
    return categorizedTypes[category] ?? [];
  }

  /// Category translations
  static const Map<String, Map<String, String>> categoryTranslations = {
    'home_property': {
      'EN': 'Home & Property',
      'PT': 'Casa e Propriedade',
      'ES': 'Hogar y Propiedad',
      'FR': 'Maison et Propriete',
      'DE': 'Haus und Grundstuck',
    },
    'automotive': {
      'EN': 'Automotive',
      'PT': 'Automovel',
      'ES': 'Automovil',
      'FR': 'Automobile',
      'DE': 'Automobil',
    },
    'personal': {
      'EN': 'Personal Services',
      'PT': 'Servicos Pessoais',
      'ES': 'Servicios Personales',
      'FR': 'Services Personnels',
      'DE': 'Persoenliche Dienste',
    },
    'professional': {
      'EN': 'Professional Services',
      'PT': 'Servicos Profissionais',
      'ES': 'Servicios Profesionales',
      'FR': 'Services Professionnels',
      'DE': 'Professionelle Dienste',
    },
    'technical': {
      'EN': 'Technical Services',
      'PT': 'Servicos Tecnicos',
      'ES': 'Servicios Tecnicos',
      'FR': 'Services Techniques',
      'DE': 'Technische Dienste',
    },
    'events': {
      'EN': 'Events & Entertainment',
      'PT': 'Eventos e Entretenimento',
      'ES': 'Eventos y Entretenimiento',
      'FR': 'Evenements et Divertissement',
      'DE': 'Veranstaltungen und Unterhaltung',
    },
    'pets': {
      'EN': 'Pet Services',
      'PT': 'Servicos para Animais',
      'ES': 'Servicios para Mascotas',
      'FR': 'Services pour Animaux',
      'DE': 'Haustierdienste',
    },
  };

  /// Service type translations
  static const Map<String, Map<String, String>> typeTranslations = {
    // Home & Property
    'plumber': {
      'EN': 'Plumber',
      'PT': 'Canalizador',
      'ES': 'Fontanero',
      'FR': 'Plombier',
      'DE': 'Klempner',
    },
    'electrician': {
      'EN': 'Electrician',
      'PT': 'Eletricista',
      'ES': 'Electricista',
      'FR': 'Electricien',
      'DE': 'Elektriker',
    },
    'carpenter': {
      'EN': 'Carpenter',
      'PT': 'Carpinteiro',
      'ES': 'Carpintero',
      'FR': 'Charpentier',
      'DE': 'Zimmermann',
    },
    'painter': {
      'EN': 'Painter',
      'PT': 'Pintor',
      'ES': 'Pintor',
      'FR': 'Peintre',
      'DE': 'Maler',
    },
    'roofer': {
      'EN': 'Roofer',
      'PT': 'Telhador',
      'ES': 'Techador',
      'FR': 'Couvreur',
      'DE': 'Dachdecker',
    },
    'gardener': {
      'EN': 'Gardener',
      'PT': 'Jardineiro',
      'ES': 'Jardinero',
      'FR': 'Jardinier',
      'DE': 'Gaertner',
    },
    'cleaner': {
      'EN': 'Cleaner',
      'PT': 'Empregado de Limpeza',
      'ES': 'Limpiador',
      'FR': 'Agent de Nettoyage',
      'DE': 'Reinigungskraft',
    },
    'handyman': {
      'EN': 'Handyman',
      'PT': 'Faz-Tudo',
      'ES': 'Manitas',
      'FR': 'Homme a Tout Faire',
      'DE': 'Handwerker',
    },
    'locksmith': {
      'EN': 'Locksmith',
      'PT': 'Serralheiro',
      'ES': 'Cerrajero',
      'FR': 'Serrurier',
      'DE': 'Schlosser',
    },
    'pest-control': {
      'EN': 'Pest Control',
      'PT': 'Controlo de Pragas',
      'ES': 'Control de Plagas',
      'FR': 'Lutte Antiparasitaire',
      'DE': 'Schaedlingsbekaempfung',
    },
    'hvac': {
      'EN': 'HVAC Technician',
      'PT': 'Tecnico AVAC',
      'ES': 'Tecnico HVAC',
      'FR': 'Technicien CVC',
      'DE': 'HLK-Techniker',
    },
    'mover': {
      'EN': 'Mover',
      'PT': 'Mudancas',
      'ES': 'Mudanzas',
      'FR': 'Demenageur',
      'DE': 'Umzugsunternehmen',
    },

    // Automotive
    'mechanic': {
      'EN': 'Mechanic',
      'PT': 'Mecanico',
      'ES': 'Mecanico',
      'FR': 'Mecanicien',
      'DE': 'Mechaniker',
    },
    'auto-electrician': {
      'EN': 'Auto Electrician',
      'PT': 'Eletricista Auto',
      'ES': 'Electricista de Autos',
      'FR': 'Electricien Auto',
      'DE': 'Autoelektriker',
    },
    'tow-service': {
      'EN': 'Tow Service',
      'PT': 'Reboque',
      'ES': 'Grua',
      'FR': 'Depannage',
      'DE': 'Abschleppdienst',
    },
    'car-wash': {
      'EN': 'Car Wash',
      'PT': 'Lavagem Auto',
      'ES': 'Lavado de Coches',
      'FR': 'Lavage Auto',
      'DE': 'Autowaesche',
    },
    'tire-service': {
      'EN': 'Tire Service',
      'PT': 'Servico de Pneus',
      'ES': 'Servicio de Neumaticos',
      'FR': 'Service de Pneus',
      'DE': 'Reifenservice',
    },
    'auto-body': {
      'EN': 'Auto Body Shop',
      'PT': 'Chapeiro',
      'ES': 'Taller de Carroceria',
      'FR': 'Carrosserie',
      'DE': 'Karosseriewerkstatt',
    },

    // Personal Services
    'tutor': {
      'EN': 'Tutor',
      'PT': 'Explicador',
      'ES': 'Tutor',
      'FR': 'Tuteur',
      'DE': 'Nachhilfelehrer',
    },
    'nurse': {
      'EN': 'Nurse',
      'PT': 'Enfermeiro',
      'ES': 'Enfermero',
      'FR': 'Infirmier',
      'DE': 'Krankenpfleger',
    },
    'caregiver': {
      'EN': 'Caregiver',
      'PT': 'Cuidador',
      'ES': 'Cuidador',
      'FR': 'Aide-Soignant',
      'DE': 'Betreuer',
    },
    'personal-trainer': {
      'EN': 'Personal Trainer',
      'PT': 'Personal Trainer',
      'ES': 'Entrenador Personal',
      'FR': 'Coach Personnel',
      'DE': 'Personal Trainer',
    },
    'massage-therapist': {
      'EN': 'Massage Therapist',
      'PT': 'Massagista',
      'ES': 'Masajista',
      'FR': 'Massotherapeute',
      'DE': 'Masseur',
    },
    'hairdresser': {
      'EN': 'Hairdresser',
      'PT': 'Cabeleireiro',
      'ES': 'Peluquero',
      'FR': 'Coiffeur',
      'DE': 'Friseur',
    },
    'barber': {
      'EN': 'Barber',
      'PT': 'Barbeiro',
      'ES': 'Barbero',
      'FR': 'Barbier',
      'DE': 'Barbier',
    },
    'beautician': {
      'EN': 'Beautician',
      'PT': 'Esteticista',
      'ES': 'Esteticista',
      'FR': 'Estheticienne',
      'DE': 'Kosmetikerin',
    },
    'tailor': {
      'EN': 'Tailor',
      'PT': 'Alfaiate',
      'ES': 'Sastre',
      'FR': 'Tailleur',
      'DE': 'Schneider',
    },
    'chef': {
      'EN': 'Personal Chef',
      'PT': 'Chef Pessoal',
      'ES': 'Chef Personal',
      'FR': 'Chef Personnel',
      'DE': 'Privatkoch',
    },

    // Professional Services
    'lawyer': {
      'EN': 'Lawyer',
      'PT': 'Advogado',
      'ES': 'Abogado',
      'FR': 'Avocat',
      'DE': 'Rechtsanwalt',
    },
    'accountant': {
      'EN': 'Accountant',
      'PT': 'Contabilista',
      'ES': 'Contable',
      'FR': 'Comptable',
      'DE': 'Buchhalter',
    },
    'notary': {
      'EN': 'Notary',
      'PT': 'Notario',
      'ES': 'Notario',
      'FR': 'Notaire',
      'DE': 'Notar',
    },
    'translator': {
      'EN': 'Translator',
      'PT': 'Tradutor',
      'ES': 'Traductor',
      'FR': 'Traducteur',
      'DE': 'Uebersetzer',
    },
    'photographer': {
      'EN': 'Photographer',
      'PT': 'Fotografo',
      'ES': 'Fotografo',
      'FR': 'Photographe',
      'DE': 'Fotograf',
    },
    'videographer': {
      'EN': 'Videographer',
      'PT': 'Videografo',
      'ES': 'Videografo',
      'FR': 'Videaste',
      'DE': 'Videograf',
    },
    'graphic-designer': {
      'EN': 'Graphic Designer',
      'PT': 'Designer Grafico',
      'ES': 'Disenador Grafico',
      'FR': 'Graphiste',
      'DE': 'Grafikdesigner',
    },
    'web-developer': {
      'EN': 'Web Developer',
      'PT': 'Desenvolvedor Web',
      'ES': 'Desarrollador Web',
      'FR': 'Developpeur Web',
      'DE': 'Webentwickler',
    },

    // Technical Services
    'it-support': {
      'EN': 'IT Support',
      'PT': 'Suporte Informatico',
      'ES': 'Soporte Informatico',
      'FR': 'Support Informatique',
      'DE': 'IT-Support',
    },
    'appliance-repair': {
      'EN': 'Appliance Repair',
      'PT': 'Reparacao de Electrodomesticos',
      'ES': 'Reparacion de Electrodomesticos',
      'FR': 'Reparation Electromenager',
      'DE': 'Geraetereparatur',
    },
    'phone-repair': {
      'EN': 'Phone Repair',
      'PT': 'Reparacao de Telemoveis',
      'ES': 'Reparacion de Moviles',
      'FR': 'Reparation de Telephones',
      'DE': 'Handyreparatur',
    },
    'computer-repair': {
      'EN': 'Computer Repair',
      'PT': 'Reparacao de Computadores',
      'ES': 'Reparacion de Ordenadores',
      'FR': 'Reparation Informatique',
      'DE': 'Computerreparatur',
    },
    'solar-installer': {
      'EN': 'Solar Installer',
      'PT': 'Instalador Solar',
      'ES': 'Instalador Solar',
      'FR': 'Installateur Solaire',
      'DE': 'Solarinstallateur',
    },
    'security-systems': {
      'EN': 'Security Systems',
      'PT': 'Sistemas de Seguranca',
      'ES': 'Sistemas de Seguridad',
      'FR': 'Systemes de Securite',
      'DE': 'Sicherheitssysteme',
    },

    // Events & Entertainment
    'dj': {
      'EN': 'DJ',
      'PT': 'DJ',
      'ES': 'DJ',
      'FR': 'DJ',
      'DE': 'DJ',
    },
    'musician': {
      'EN': 'Musician',
      'PT': 'Musico',
      'ES': 'Musico',
      'FR': 'Musicien',
      'DE': 'Musiker',
    },
    'event-planner': {
      'EN': 'Event Planner',
      'PT': 'Organizador de Eventos',
      'ES': 'Organizador de Eventos',
      'FR': 'Organisateur d\'Evenements',
      'DE': 'Eventplaner',
    },
    'caterer': {
      'EN': 'Caterer',
      'PT': 'Catering',
      'ES': 'Catering',
      'FR': 'Traiteur',
      'DE': 'Caterer',
    },

    // Pet Services
    'veterinarian': {
      'EN': 'Veterinarian',
      'PT': 'Veterinario',
      'ES': 'Veterinario',
      'FR': 'Veterinaire',
      'DE': 'Tierarzt',
    },
    'pet-groomer': {
      'EN': 'Pet Groomer',
      'PT': 'Tosquiador de Animais',
      'ES': 'Peluquero de Mascotas',
      'FR': 'Toiletteur pour Animaux',
      'DE': 'Tierpfleger',
    },
    'pet-sitter': {
      'EN': 'Pet Sitter',
      'PT': 'Pet Sitter',
      'ES': 'Cuidador de Mascotas',
      'FR': 'Gardien d\'Animaux',
      'DE': 'Tiersitter',
    },
    'dog-walker': {
      'EN': 'Dog Walker',
      'PT': 'Passeador de Caes',
      'ES': 'Paseador de Perros',
      'FR': 'Promeneur de Chiens',
      'DE': 'Hundeausführer',
    },
  };

  /// Get translated name for a service type
  static String getTypeName(String type, String langCode) {
    final upperCode = langCode.toUpperCase();
    final translations = typeTranslations[type];
    if (translations == null) {
      // Return type key with first letter capitalized
      return type.replaceAll('-', ' ').split(' ').map((word) {
        if (word.isEmpty) return word;
        return word[0].toUpperCase() + word.substring(1);
      }).join(' ');
    }
    return translations[upperCode] ??
        translations['EN'] ??
        translations.values.first;
  }

  /// Get translated name for a category
  static String getCategoryName(String category, String langCode) {
    final upperCode = langCode.toUpperCase();
    final translations = categoryTranslations[category];
    if (translations == null) {
      return category.replaceAll('_', ' ').split(' ').map((word) {
        if (word.isEmpty) return word;
        return word[0].toUpperCase() + word.substring(1);
      }).join(' ');
    }
    return translations[upperCode] ??
        translations['EN'] ??
        translations.values.first;
  }

  /// Get all categories
  static List<String> get categories => categorizedTypes.keys.toList();

  /// Search types by name (in any language)
  static List<String> searchTypes(String query) {
    if (query.isEmpty) return allTypes;

    final lowerQuery = query.toLowerCase();
    final results = <String>[];

    for (final type in allTypes) {
      // Check if type key matches
      if (type.contains(lowerQuery)) {
        results.add(type);
        continue;
      }

      // Check if any translation matches
      final translations = typeTranslations[type];
      if (translations != null) {
        for (final translation in translations.values) {
          if (translation.toLowerCase().contains(lowerQuery)) {
            results.add(type);
            break;
          }
        }
      }
    }

    return results;
  }
}
