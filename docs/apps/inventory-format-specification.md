# Inventory Format Specification

**Version**: 1.0
**Last Updated**: 2026-01-01
**Status**: Draft

## Table of Contents

- [Overview](#overview)
- [File Organization](#file-organization)
- [Folder Format](#folder-format)
- [Item Format](#item-format)
- [Measurement Units](#measurement-units)
- [Item Type System](#item-type-system)
- [Usage and Refill Tracking](#usage-and-refill-tracking)
- [Borrowing System](#borrowing-system)
- [Templates System](#templates-system)
- [Media Management](#media-management)
- [Multilanguage Support](#multilanguage-support)
- [Visibility and Sharing](#visibility-and-sharing)
- [Security Configuration](#security-configuration)
- [Complete Examples](#complete-examples)
- [Parsing Implementation](#parsing-implementation)
- [Validation Rules](#validation-rules)
- [Best Practices](#best-practices)
- [Related Documentation](#related-documentation)
- [Change Log](#change-log)

## Overview

This document specifies the JSON-based format used for storing inventory data in the Geogram system. The inventory collection type enables users to track personal or shared inventories with folder-based organization, item tracking, borrowing management, and flexible visibility controls.

### Key Features

- **Folder-Based Organization**: Create folders and subfolders (max 5 levels) to organize inventory
- **Private by Default**: All data is private, with options to share with groups or make public
- **Comprehensive Item Tracking**: Track title, type, quantity, purchase date, expiration, and media
- **Measurement Units**: Support for liters, kilos, meters, units, and more
- **Usage & Refill Tracking**: Track consumption and refilling of consumable items
- **200+ Item Types**: Predefined types for off-grid contexts (vehicles, tools, food, equipment, etc.)
- **Type-Specific Fields**: Each item type has relevant predefined fields plus custom fields
- **Searchable Type Selection**: Find types quickly with search and category browsing
- **Templates System**: Define item templates for quick creation of frequently added items
- **Borrowing System**: Track multiple borrow events per item with callsign or free text borrowers
- **Media Attachments**: Pictures stored in folder-level `media/` subfolder for easy access
- **Multilanguage Support**: Translate titles, descriptions, types, and units for 11 languages
- **Offline-First**: Complete functionality without internet connection
- **NOSTR Signatures**: Cryptographic verification for all content
- **Group Sharing**: Share folders or items with specific groups
- **Sync Support**: Data syncs via P2P collection distribution

### Conceptual Model

The Geogram inventory collection works as a personal asset manager:

1. **Owner** creates folders to organize different inventory categories
2. **Items** are created within folders with detailed information
3. **Borrowing** tracks who has borrowed items and quantities
4. **Visibility** controls whether data is private, shared with groups, or public
5. **No Central Authority**: Everything is stored locally and syncs peer-to-peer

## File Organization

### Directory Structure

```
inventory/                           # Collection root
├── metadata.json                    # Collection metadata
├── templates/                       # Item templates
│   ├── template_gasoline.json
│   └── template_canned_tomatoes.json
├── extra/
│   └── security.json                # Admins, moderators, permissions
└── folders/                         # All folders stored here
    ├── vehicles/                    # Folder (depth 0)
    │   ├── folder.json              # Folder metadata
    │   ├── media/                   # Media for all items in this folder
    │   │   ├── a1b2c3_front.jpg
    │   │   └── d4e5f6_side.jpg
    │   ├── items/                   # Items in this folder
    │   │   ├── item_20250101_abc123/
    │   │   │   ├── item.json        # Item data
    │   │   │   ├── usage.json       # Usage/refill history
    │   │   │   └── borrows.json     # Borrow history
    │   │   └── item_20250101_def456/
    │   │       └── item.json
    │   └── cars/                    # Subfolder (depth 1)
    │       ├── folder.json
    │       ├── media/               # Media for this subfolder's items
    │       └── items/
    │           └── item_20250102_ghi789/
    │               ├── item.json
    │               └── borrows.json
    ├── tools/                       # Another root folder
    │   ├── folder.json
    │   ├── media/
    │   ├── items/
    │   └── power-tools/             # Subfolder
    │       ├── folder.json
    │       ├── media/
    │       └── items/
    └── fuel/
        ├── folder.json
        ├── media/
        └── items/
            └── item_20250101_gasoline/
                ├── item.json        # Has batches for different purchases
                └── usage.json       # Consumption and refill events
```

### Folder Naming

**Pattern**: Filesystem-safe folder names

**Rules**:
- Lowercase letters, numbers, hyphens, underscores only
- No spaces (use hyphens or underscores)
- Maximum 50 characters
- Must be unique within parent folder

**Examples**:
```
vehicles/
tools/
power-tools/
food-storage/
medical_supplies/
```

### Item Folder Naming

**Pattern**: `item_{timestamp}_{random}`

**Components**:
- `item_`: Prefix for identification
- `{timestamp}`: Creation date as YYYYMMDD
- `{random}`: 6 random alphanumeric characters

**Examples**:
```
item_20250101_abc123/
item_20250115_xyz789/
item_20251225_qwerty/
```

### Maximum Folder Depth

The inventory supports a maximum of **5 levels** of folder nesting:

```
folders/                    # Level 0 (root)
└── vehicles/               # Level 1
    └── cars/               # Level 2
        └── sedans/         # Level 3
            └── toyota/     # Level 4
                └── camry/  # Level 5 (maximum)
```

Attempting to create folders beyond level 5 should be rejected by the service.

## Folder Format

### folder.json

Every folder must have a `folder.json` file with metadata.

**Required Fields**:
```json
{
  "id": "folder_vehicles",
  "name": "Vehicles",
  "parent_id": null,
  "depth": 0,
  "created_at": "2025-01-01T10:00:00Z",
  "modified_at": "2025-01-01T10:00:00Z",
  "owner_callsign": "X1ABCD"
}
```

**Optional Fields**:
```json
{
  "description": "All motorized and non-motorized vehicles",
  "visibility": "private",
  "shared_groups": [],
  "icon": "car",
  "color": "#4CAF50",
  "metadata": {
    "npub": "npub1...",
    "signature": "sig..."
  }
}
```

### Field Descriptions

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique folder identifier |
| `name` | string | Yes | Display name (can include spaces, special chars) |
| `parent_id` | string/null | Yes | Parent folder ID, null for root folders |
| `depth` | integer | Yes | Nesting level (0-5) |
| `created_at` | ISO 8601 | Yes | Creation timestamp |
| `modified_at` | ISO 8601 | Yes | Last modification timestamp |
| `owner_callsign` | string | Yes | Creator's callsign |
| `description` | string | No | Optional folder description |
| `visibility` | string | No | "private", "group", or "public" (default: "private") |
| `shared_groups` | array | No | Group IDs if visibility is "group" |
| `icon` | string | No | Icon identifier for UI |
| `color` | string | No | Hex color for UI theming |
| `metadata` | object | No | NOSTR npub and signature |

### Visibility Values

- **`private`** (default): Only owner can view/edit
- **`group`**: Owner and specified groups can view
- **`public`**: Anyone can view, only owner can edit

## Item Format

### item.json

Every item must have an `item.json` file with complete item data.

**Required Fields**:
```json
{
  "id": "item_20250101_abc123",
  "title": "Honda Civic 1999",
  "type": "car",
  "quantity": 1,
  "unit": "units",
  "created_at": "2025-01-01T10:00:00Z",
  "modified_at": "2025-01-01T10:00:00Z",
  "owner_callsign": "X1ABCD"
}
```

**Optional Fields**:
```json
{
  "description": "Blue sedan in good condition, regular maintenance",
  "initial_quantity": 1,
  "current_quantity": 1,
  "date_purchased": "2020-05-15",
  "date_expired": null,
  "visibility": "private",
  "shared_groups": [],
  "media": [
    {
      "filename": "a1b2c3_front.jpg",
      "hash": "a1b2c3d4e5f6...",
      "size": 2097152,
      "mime_type": "image/jpeg",
      "added_at": "2025-01-01T10:00:00Z"
    }
  ],
  "batches": [
    {
      "id": "batch_001",
      "quantity": 12,
      "date_purchased": "2025-01-01",
      "date_expired": "2027-06-15",
      "cost": 24.99,
      "notes": "Bought at Costco"
    },
    {
      "id": "batch_002",
      "quantity": 6,
      "date_purchased": "2025-06-15",
      "date_expired": "2028-01-20",
      "cost": 13.50,
      "notes": "Local store sale"
    }
  ],
  "specs": {
    "brand": "Honda",
    "model": "Civic",
    "year": 1999,
    "vin": "2HGCJ566X9H512345",
    "mileage": 185000,
    "fuel_type": "gasoline",
    "color": "blue",
    "license_plate": "AB-12-CD"
  },
  "custom_fields": {
    "garage_location": "Bay 3",
    "insurance_policy": "POL-12345",
    "last_service_date": "2024-11-15"
  },
  "tags": ["daily-driver", "needs-oil-change"],
  "notes": "Check brakes before winter",
  "metadata": {
    "npub": "npub1...",
    "signature": "sig..."
  }
}
```

### Field Descriptions

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique item identifier |
| `title` | string | Yes | Item name/title |
| `type` | string | Yes | Item type from type catalog |
| `quantity` | number | Yes | Total quantity (sum of batches or single value) |
| `unit` | string | Yes | Measurement unit (see Measurement Units section) |
| `created_at` | ISO 8601 | Yes | Creation timestamp |
| `modified_at` | ISO 8601 | Yes | Last modification timestamp |
| `owner_callsign` | string | Yes | Creator's callsign |
| `description` | string | No | Detailed description |
| `initial_quantity` | number | No | Original quantity when item was created |
| `current_quantity` | number | No | Current quantity after usage/refills |
| `date_purchased` | YYYY-MM-DD | No | Purchase/acquisition date (for single-batch items) |
| `date_expired` | YYYY-MM-DD | No | Expiration date (for single-batch items) |
| `visibility` | string | No | "private", "group", or "public" |
| `shared_groups` | array | No | Group IDs if visibility is "group" |
| `media` | array | No | Media file references (stored in folder's media/) |
| `batches` | array | No | Multiple batches with different expiry dates |
| `specs` | object | No | Type-specific fields |
| `custom_fields` | object | No | User-defined fields |
| `tags` | array | No | Searchable tags |
| `notes` | string | No | Additional notes |
| `metadata` | object | No | NOSTR npub and signature |

### Batches for Stock Management

For items that need to track multiple lots with different expiration dates (like food supplies), use the `batches` array:

```json
{
  "id": "item_20250101_tomatoes",
  "title": "Canned Tomatoes",
  "type": "canned_vegetables",
  "quantity": 18,
  "unit": "units",
  "batches": [
    {
      "id": "batch_001",
      "quantity": 12,
      "date_purchased": "2025-01-01",
      "date_expired": "2027-06-15",
      "cost": 24.99,
      "supplier": "Costco",
      "notes": "San Marzano organic"
    },
    {
      "id": "batch_002",
      "quantity": 6,
      "date_purchased": "2025-03-15",
      "date_expired": "2027-12-01",
      "cost": 12.00,
      "supplier": "Local grocery"
    }
  ]
}
```

**Batch Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique batch identifier |
| `quantity` | number | Yes | Quantity in this batch |
| `date_purchased` | YYYY-MM-DD | No | When this batch was acquired |
| `date_expired` | YYYY-MM-DD | No | Expiration date for this batch |
| `cost` | number | No | Purchase cost for this batch |
| `supplier` | string | No | Where this batch was purchased |
| `notes` | string | No | Batch-specific notes |

**Stock Management Rules**:
- Total `quantity` should equal sum of all batch quantities minus usage
- When consuming, prefer FIFO (First In, First Out) by expiration date
- Expired batches should be flagged but not automatically removed

## Measurement Units

Every item must specify a measurement unit. This enables proper tracking of consumption and refills.

### Supported Units

#### Volume
| Unit ID | Display Name | Symbol | Category |
|---------|--------------|--------|----------|
| `liters` | Liters | L | volume |
| `milliliters` | Milliliters | mL | volume |
| `gallons` | Gallons (US) | gal | volume |
| `quarts` | Quarts | qt | volume |
| `pints` | Pints | pt | volume |
| `cups` | Cups | cup | volume |
| `fluid_oz` | Fluid Ounces | fl oz | volume |

#### Weight/Mass
| Unit ID | Display Name | Symbol | Category |
|---------|--------------|--------|----------|
| `kilograms` | Kilograms | kg | weight |
| `grams` | Grams | g | weight |
| `milligrams` | Milligrams | mg | weight |
| `pounds` | Pounds | lb | weight |
| `ounces` | Ounces | oz | weight |
| `tons` | Metric Tons | t | weight |

#### Length/Distance
| Unit ID | Display Name | Symbol | Category |
|---------|--------------|--------|----------|
| `meters` | Meters | m | length |
| `centimeters` | Centimeters | cm | length |
| `millimeters` | Millimeters | mm | length |
| `kilometers` | Kilometers | km | length |
| `feet` | Feet | ft | length |
| `inches` | Inches | in | length |
| `yards` | Yards | yd | length |
| `miles` | Miles | mi | length |

#### Area
| Unit ID | Display Name | Symbol | Category |
|---------|--------------|--------|----------|
| `square_meters` | Square Meters | m² | area |
| `square_feet` | Square Feet | ft² | area |
| `acres` | Acres | ac | area |
| `hectares` | Hectares | ha | area |

#### Count/Discrete
| Unit ID | Display Name | Symbol | Category |
|---------|--------------|--------|----------|
| `units` | Units | units | count |
| `pieces` | Pieces | pcs | count |
| `pairs` | Pairs | pairs | count |
| `dozen` | Dozen | doz | count |
| `boxes` | Boxes | boxes | count |
| `cases` | Cases | cases | count |
| `packs` | Packs | packs | count |
| `bags` | Bags | bags | count |
| `rolls` | Rolls | rolls | count |
| `sheets` | Sheets | sheets | count |
| `bottles` | Bottles | bottles | count |
| `cans` | Cans | cans | count |
| `jars` | Jars | jars | count |

#### Time/Duration
| Unit ID | Display Name | Symbol | Category |
|---------|--------------|--------|----------|
| `hours` | Hours | hrs | time |
| `days` | Days | days | time |
| `weeks` | Weeks | wks | time |
| `months` | Months | mos | time |

#### Other
| Unit ID | Display Name | Symbol | Category |
|---------|--------------|--------|----------|
| `percent` | Percent | % | other |
| `custom` | Custom | - | other |

### Unit Selection by Item Type

Certain item types have recommended default units:

| Item Type Category | Recommended Unit |
|--------------------|------------------|
| Vehicles | `units` |
| Tools | `units` |
| Fuel (gasoline, diesel, propane) | `liters` or `gallons` |
| Food - Liquids (oil, vinegar, milk) | `liters` |
| Food - Dry goods (flour, rice, sugar) | `kilograms` or `pounds` |
| Food - Canned/packaged | `units` or `cans` |
| Hardware (screws, nails, bolts) | `units` or `pieces` |
| Lumber | `meters` or `feet` |
| Fabric/Textiles | `meters` or `yards` |
| Rope/Wire/Cable | `meters` or `feet` |

### Custom Units

If none of the predefined units fit, use `custom` and specify the unit name in `custom_fields`:

```json
{
  "unit": "custom",
  "custom_fields": {
    "custom_unit": "bushels",
    "custom_unit_symbol": "bu"
  }
}
```

## Item Type System

### Type Selection UI

The item type selection interface should provide:

1. **Search Box**: Text filter to find types quickly
2. **Category Browsing**: Types organized by category
3. **Recently Used**: Show user's recently used types at top
4. **Custom/Other**: Option to use "other" if no predefined type fits

### Type Categories (200+ Types)

#### Vehicles (19 types)
```
car, van, truck, motorcycle, bicycle, e-bike, scooter, trailer, boat,
kayak, canoe, atv, tractor, forklift, golf_cart, snowmobile, jet_ski, rv, camper
```

#### Tools - Hand (26 types)
```
hammer, screwdriver, pliers, wrench, socket_set, allen_keys, tape_measure,
level, chisel, file, rasp, handsaw, hacksaw, clamp, vise, crowbar, pry_bar,
wire_cutter, wire_stripper, crimper, multitool, knife, utility_knife,
scissors, tin_snips, bolt_cutter
```

#### Tools - Power (24 types)
```
drill, impact_driver, circular_saw, jigsaw, reciprocating_saw, miter_saw,
table_saw, band_saw, angle_grinder, bench_grinder, sander, router, planer,
nail_gun, staple_gun, heat_gun, soldering_iron, welder, plasma_cutter,
air_compressor, pressure_washer, chainsaw, leaf_blower, string_trimmer
```

#### Tools - Garden (20 types)
```
shovel, spade, rake, hoe, trowel, pruning_shears, loppers, hedge_trimmer,
lawn_mower, wheelbarrow, garden_fork, post_hole_digger, pickaxe, mattock,
scythe, sickle, watering_can, hose, sprinkler, seed_spreader
```

#### Hardware & Fasteners (25 types)
```
screws, nails, bolts, nuts, washers, anchors, hooks, brackets, hinges,
latches, locks, chains, cables, wire, rope, cord, tape, adhesive, glue,
epoxy, sealant, caulk, zip_ties, clamps, straps
```

#### Containers (20 types)
```
bucket, barrel, drum, tank, bin, box, crate, tote, basket, bag, sack,
canister, jar, bottle, jug, cooler, thermos, toolbox, storage_box, ammo_can
```

#### Electrical (22 types)
```
battery, charger, inverter, solar_panel, generator, extension_cord,
power_strip, light_bulb, flashlight, headlamp, lantern, spotlight, wire,
cable, fuse, breaker, switch, outlet, plug, connector, multimeter, voltage_tester
```

#### Plumbing (18 types)
```
pipe, fitting, valve, faucet, pump, hose, clamp, sealant, plunger, snake,
wrench, cutter, torch, solder, flux, teflon_tape, pvc_cement, water_filter, water_tank
```

#### Building Materials (20 types)
```
lumber, plywood, osb, drywall, insulation, roofing, siding, cement, concrete,
mortar, brick, block, stone, gravel, sand, rebar, mesh, flashing, tar_paper, house_wrap
```

#### Safety & PPE (17 types)
```
gloves, safety_glasses, goggles, face_shield, hard_hat, ear_plugs, ear_muffs,
respirator, dust_mask, safety_vest, steel_toe_boots, harness, lanyard,
fire_extinguisher, first_aid_kit, smoke_detector, co_detector
```

#### Camping & Outdoor (23 types)
```
tent, sleeping_bag, sleeping_pad, backpack, tarp, paracord, compass, gps,
radio, walkie_talkie, binoculars, fire_starter, matches, lighter, stove,
cookware, water_bottle, water_filter, headlamp, lantern, axe, hatchet, machete
```

#### Food - Staples (21 types)
```
rice, beans, flour, sugar, salt, oil, vinegar, honey, pasta, oats, cornmeal,
wheat, barley, lentils, chickpeas, dried_fruit, nuts, seeds, powdered_milk, coffee, tea
```

#### Food - Preserved (14 types)
```
canned_vegetables, canned_fruit, canned_meat, canned_fish, canned_soup,
canned_beans, pickles, jam, jelly, peanut_butter, dried_meat, jerky,
freeze_dried, mre
```

#### Food - Fresh (9 types)
```
vegetables, fruits, eggs, meat, poultry, fish, dairy, bread, herbs
```

#### Drinks (9 types)
```
water, juice, soda, beer, wine, spirits, energy_drink, sports_drink, milk
```

#### Kitchen (25 types)
```
pot, pan, skillet, dutch_oven, kettle, coffee_maker, blender, mixer, toaster,
microwave, stove, oven, refrigerator, freezer, knife_set, cutting_board,
utensils, plates, bowls, cups, glasses, storage_containers, canning_jars,
pressure_canner, dehydrator, vacuum_sealer
```

#### Cleaning (14 types)
```
broom, mop, bucket, vacuum, duster, sponge, brush, soap, detergent, bleach,
disinfectant, trash_bags, paper_towels, rags
```

#### Fuel & Energy (10 types)
```
gasoline, diesel, propane, kerosene, firewood, charcoal, pellets,
solar_battery, fuel_container, fuel_stabilizer
```

#### Medical & Health (16 types)
```
bandages, gauze, tape, antiseptic, antibiotics, painkillers, thermometer,
blood_pressure_monitor, stethoscope, splint, tourniquet, epipen, inhaler,
prescription_meds, vitamins, supplements
```

#### Communication & Electronics (23 types)
```
radio, ham_radio, cb_radio, walkie_talkie, phone, smartphone, tablet, laptop,
computer, monitor, keyboard, mouse, camera, video_camera, drone, gps,
satellite_phone, antenna, cable, charger, power_bank, sd_card, hard_drive, usb_drive
```

#### Clothing & Textiles (21 types)
```
jacket, coat, pants, shirt, boots, shoes, socks, gloves, hat, scarf, blanket,
towel, tarp, canvas, fabric, thread, needle, sewing_machine, zipper, button, velcro
```

#### Livestock & Animals (14 types)
```
feed, hay, straw, bedding, fence, gate, waterer, feeder, halter, lead, saddle,
bridle, coop, hutch, cage, aquarium, pet_food, veterinary_supplies
```

#### Seeds & Growing (22 types)
```
vegetable_seeds, herb_seeds, flower_seeds, fruit_seeds, seedling, plant, tree,
fertilizer, compost, mulch, soil, peat_moss, perlite, grow_light, greenhouse,
cold_frame, row_cover, trellis, stake, pot, planter
```

#### Documents & Records (15 types)
```
deed, title, registration, license, permit, certificate, contract, receipt,
manual, map, blueprint, warranty, insurance_policy, passport, id_card
```

#### Furniture (12 types)
```
table, chair, desk, shelf, cabinet, dresser, bed, mattress, couch, bench, stool, rack
```

#### Recreation (13 types)
```
fishing_rod, tackle_box, hunting_rifle, shotgun, bow, crossbow, ammunition,
archery_target, game_camera, decoy, call, trap, snare
```

#### Other (1 type)
```
other
```

### Type-Specific Field Schemas

Each type category has predefined fields in the `specs` object:

#### Vehicle Types (car, van, truck, motorcycle, etc.)
```json
{
  "brand": "string",
  "model": "string",
  "year": "integer",
  "vin": "string",
  "mileage": "integer",
  "fuel_type": "string (gasoline|diesel|electric|hybrid|propane)",
  "transmission": "string (manual|automatic)",
  "color": "string",
  "license_plate": "string",
  "insurance_expiry": "date"
}
```

#### Tool Types (all tools)
```json
{
  "brand": "string",
  "model": "string",
  "condition": "string (new|good|fair|poor)",
  "power_source": "string (manual|electric|battery|pneumatic|gas)",
  "voltage": "integer",
  "warranty_until": "date"
}
```

#### Food Types (all food/drink)
```json
{
  "expiration_date": "date",
  "storage_temp": "string (frozen|refrigerated|room_temp)",
  "organic": "boolean",
  "quantity_unit": "string (kg|lb|g|oz|liters|gallons|count)",
  "calories_per_serving": "integer",
  "allergens": "array of strings"
}
```

#### Container Types
```json
{
  "capacity": "number",
  "capacity_unit": "string (liters|gallons|ml|oz)",
  "material": "string (plastic|metal|glass|wood)",
  "food_safe": "boolean",
  "lid_type": "string (screw|snap|none)"
}
```

#### Electrical Types
```json
{
  "voltage": "integer",
  "amperage": "number",
  "wattage": "integer",
  "battery_type": "string (AA|AAA|C|D|9V|lithium|lead_acid)",
  "capacity_mah": "integer"
}
```

#### Document Types
```json
{
  "document_number": "string",
  "issue_date": "date",
  "expiry_date": "date",
  "issuing_authority": "string"
}
```

#### Seed Types
```json
{
  "variety": "string",
  "germination_rate": "integer (percentage)",
  "days_to_harvest": "integer",
  "planting_season": "string (spring|summer|fall|winter)",
  "seed_count": "integer"
}
```

### Custom Fields

All items support a `custom_fields` object for user-defined fields not in the schema:

```json
{
  "custom_fields": {
    "garage_location": "Bay 3",
    "insurance_policy": "POL-12345",
    "purchased_from": "Local Hardware Store",
    "maintenance_notes": "Oil change every 3000 miles"
  }
}
```

## Usage and Refill Tracking

### Overview

For consumable items (fuel, food, supplies), track usage (consumption) and refills over time. This enables:
- Monitoring consumption rates
- Planning restocking needs
- Historical usage analysis
- Tracking which batches were consumed (FIFO)

### usage.json

Items with usage tracking have a `usage.json` file in their folder.

**Format**:
```json
{
  "item_id": "item_20250101_gasoline",
  "events": [
    {
      "id": "usage_20251215_001",
      "type": "consume",
      "quantity": 4,
      "unit": "liters",
      "date": "2025-12-15T08:30:00Z",
      "batch_id": "batch_001",
      "reason": "Generator refuel",
      "notes": "Weekly generator maintenance"
    },
    {
      "id": "usage_20251220_001",
      "type": "refill",
      "quantity": 20,
      "unit": "liters",
      "date": "2025-12-20T14:00:00Z",
      "batch_id": "batch_002",
      "cost": 45.50,
      "supplier": "Gas station on Main St",
      "notes": "Topped up jerry cans"
    },
    {
      "id": "usage_20251222_001",
      "type": "consume",
      "quantity": 2.5,
      "unit": "liters",
      "date": "2025-12-22T10:15:00Z",
      "batch_id": "batch_001",
      "reason": "Chainsaw",
      "notes": "Clearing fallen tree"
    }
  ]
}
```

### Usage Event Types

#### Consume Events

Record when quantity is used/consumed from the item.

```json
{
  "id": "usage_20251215_001",
  "type": "consume",
  "quantity": 4,
  "unit": "liters",
  "date": "2025-12-15T08:30:00Z",
  "batch_id": "batch_001",
  "reason": "Generator refuel",
  "notes": "Weekly maintenance"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique event identifier |
| `type` | string | Yes | Always "consume" |
| `quantity` | number | Yes | Amount consumed |
| `unit` | string | Yes | Unit of measurement |
| `date` | ISO 8601 | Yes | When consumption occurred |
| `batch_id` | string | No | Which batch was consumed (for FIFO tracking) |
| `reason` | string | No | What the item was used for |
| `notes` | string | No | Additional notes |

#### Refill Events

Record when quantity is added to the item (restocking, refilling).

```json
{
  "id": "usage_20251220_001",
  "type": "refill",
  "quantity": 20,
  "unit": "liters",
  "date": "2025-12-20T14:00:00Z",
  "batch_id": "batch_002",
  "cost": 45.50,
  "supplier": "Gas station",
  "date_expired": "2026-12-20",
  "notes": "Topped up reserves"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique event identifier |
| `type` | string | Yes | Always "refill" |
| `quantity` | number | Yes | Amount added |
| `unit` | string | Yes | Unit of measurement |
| `date` | ISO 8601 | Yes | When refill occurred |
| `batch_id` | string | No | Creates or adds to a batch |
| `cost` | number | No | Cost of this refill |
| `supplier` | string | No | Where purchased/obtained |
| `date_expired` | YYYY-MM-DD | No | Expiration date for new batch |
| `notes` | string | No | Additional notes |

#### Adjustment Events

Record corrections when physical count differs from tracked quantity.

```json
{
  "id": "usage_20251225_001",
  "type": "adjustment",
  "quantity": -2,
  "unit": "liters",
  "date": "2025-12-25T09:00:00Z",
  "reason": "inventory_count",
  "notes": "Physical count showed 2L less than recorded - possible spillage"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique event identifier |
| `type` | string | Yes | Always "adjustment" |
| `quantity` | number | Yes | Adjustment amount (positive or negative) |
| `unit` | string | Yes | Unit of measurement |
| `date` | ISO 8601 | Yes | When adjustment was made |
| `reason` | string | No | Reason: inventory_count, damage, spoilage, other |
| `notes` | string | No | Explanation of discrepancy |

### Event ID Format

**Pattern**: `usage_{YYYYMMDD}_{NNN}`

- `{YYYYMMDD}`: Date of event
- `{NNN}`: Sequential number for that day (001, 002, etc.)

### Current Quantity Calculation

```
current_quantity = initial_quantity
                 + sum(refill events)
                 - sum(consume events)
                 + sum(adjustment events)
```

### Example: Gasoline Tracking

**Initial State** (item.json):
```json
{
  "id": "item_20250101_gasoline",
  "title": "Gasoline Reserve",
  "type": "gasoline",
  "initial_quantity": 40,
  "current_quantity": 33.5,
  "unit": "liters",
  "batches": [
    {
      "id": "batch_001",
      "quantity": 13.5,
      "date_purchased": "2025-11-01",
      "date_expired": "2026-05-01"
    },
    {
      "id": "batch_002",
      "quantity": 20,
      "date_purchased": "2025-12-20",
      "date_expired": "2026-06-20"
    }
  ]
}
```

**Usage History** (usage.json):
```json
{
  "item_id": "item_20250101_gasoline",
  "events": [
    {
      "id": "usage_20251201_001",
      "type": "consume",
      "quantity": 4,
      "unit": "liters",
      "date": "2025-12-01T08:00:00Z",
      "batch_id": "batch_001",
      "reason": "Generator"
    },
    {
      "id": "usage_20251215_001",
      "type": "consume",
      "quantity": 2.5,
      "unit": "liters",
      "date": "2025-12-15T10:00:00Z",
      "batch_id": "batch_001",
      "reason": "Chainsaw"
    },
    {
      "id": "usage_20251220_001",
      "type": "refill",
      "quantity": 20,
      "unit": "liters",
      "date": "2025-12-20T14:00:00Z",
      "batch_id": "batch_002",
      "cost": 45.50,
      "supplier": "Gas station"
    }
  ]
}
```

**Calculation**:
- Initial: 40L (20L batch_001)
- Consumed: 4L + 2.5L = 6.5L from batch_001
- Refilled: 20L (new batch_002)
- Current: 40 - 6.5 + 20 = 53.5L... wait, let me recalculate
- Actually initial was 20L (batch_001), consumed 6.5L, refilled 20L (batch_002)
- Current: 20 - 6.5 + 20 = 33.5L ✓

## Borrowing System

### borrows.json

Items can have an optional `borrows.json` file to track borrowing history.

**Format**:
```json
{
  "item_id": "item_20250101_abc123",
  "borrows": [
    {
      "id": "borrow_20251211_001",
      "quantity": 5,
      "borrower_type": "callsign",
      "borrower_callsign": "Y2EFGH",
      "borrower_text": null,
      "borrowed_at": "2025-12-11T10:00:00Z",
      "expected_return": "2025-12-25T10:00:00Z",
      "returned_at": null,
      "notes": "For winter project"
    },
    {
      "id": "borrow_20251215_002",
      "quantity": 2,
      "borrower_type": "text",
      "borrower_callsign": null,
      "borrower_text": "My neighbor John",
      "borrowed_at": "2025-12-15T14:00:00Z",
      "expected_return": null,
      "returned_at": "2025-12-20T09:00:00Z",
      "notes": "Returned in good condition"
    }
  ]
}
```

### Borrow Event Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique borrow event ID |
| `quantity` | integer | Yes | Number of items borrowed |
| `borrower_type` | string | Yes | "callsign" or "text" |
| `borrower_callsign` | string | Conditional | Borrower's callsign (if type is "callsign") |
| `borrower_text` | string | Conditional | Free text description (if type is "text") |
| `borrowed_at` | ISO 8601 | Yes | When items were borrowed |
| `expected_return` | ISO 8601 | No | Expected return date |
| `returned_at` | ISO 8601 | No | Actual return date (null if not returned) |
| `notes` | string | No | Additional notes |

### Borrow ID Format

**Pattern**: `borrow_{YYYYMMDD}_{NNN}`

- `{YYYYMMDD}`: Date of borrow event
- `{NNN}`: Sequential number for that day

### Available Quantity Calculation

```
available_quantity = item.quantity - sum(active_borrows.quantity)
```

Where `active_borrows` are borrow events where `returned_at` is null.

## Templates System

### Overview

Templates allow users to define item presets with default values for quick item creation. This is useful for items you frequently add to inventory, such as regular supplies.

### Template Storage

Templates are stored in the `templates/` folder at the inventory root.

**Directory Structure**:
```
inventory/
└── templates/
    ├── template_gasoline.json
    ├── template_canned_tomatoes.json
    ├── template_chicken_feed.json
    └── template_rubber_gloves.json
```

### Template Format

**File**: `templates/template_gasoline.json`

```json
{
  "id": "template_gasoline",
  "name": "Gasoline (Jerry Can)",
  "description": "20L gasoline for generators and equipment",
  "item_defaults": {
    "title": "Gasoline",
    "type": "gasoline",
    "unit": "liters",
    "quantity": 20,
    "specs": {
      "storage_temp": "room_temp",
      "container_type": "jerry_can"
    },
    "custom_fields": {
      "storage_location": "Fuel shed"
    },
    "tags": ["fuel", "generator"]
  },
  "created_at": "2025-01-01T10:00:00Z",
  "modified_at": "2025-01-01T10:00:00Z",
  "owner_callsign": "X1ABCD",
  "use_count": 15
}
```

### Template Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique template identifier |
| `name` | string | Yes | Display name for the template |
| `description` | string | No | What this template is for |
| `item_defaults` | object | Yes | Default values for new items |
| `created_at` | ISO 8601 | Yes | When template was created |
| `modified_at` | ISO 8601 | Yes | Last modification timestamp |
| `owner_callsign` | string | Yes | Creator's callsign |
| `use_count` | integer | No | How many times this template was used |

### Item Defaults Object

The `item_defaults` object can contain any field from item.json:

```json
{
  "item_defaults": {
    "title": "Default Title",
    "type": "item_type",
    "unit": "units",
    "quantity": 1,
    "description": "Default description",
    "visibility": "private",
    "specs": { ... },
    "custom_fields": { ... },
    "tags": [ ... ]
  }
}
```

### Using Templates

When creating a new item from a template:

1. Load template defaults
2. User can override any default value
3. Required fields (id, created_at, owner_callsign) are generated
4. Optional: prompt user for batch info (quantity, expiry, cost)

### Template Examples

**Canned Food Template**:
```json
{
  "id": "template_canned_tomatoes",
  "name": "Canned Tomatoes (Case)",
  "description": "Case of 12 canned tomatoes",
  "item_defaults": {
    "title": "Canned Tomatoes",
    "type": "canned_vegetables",
    "unit": "cans",
    "quantity": 12,
    "specs": {
      "storage_temp": "room_temp",
      "organic": false,
      "quantity_unit": "count"
    },
    "tags": ["pantry", "canned-goods"]
  }
}
```

**Supplies Template**:
```json
{
  "id": "template_rubber_gloves",
  "name": "Rubber Gloves (Box)",
  "description": "Box of disposable rubber gloves",
  "item_defaults": {
    "title": "Rubber Gloves",
    "type": "gloves",
    "unit": "pairs",
    "quantity": 100,
    "specs": {
      "material": "nitrile",
      "size": "large"
    },
    "tags": ["ppe", "disposable"]
  }
}
```

**Feed Template**:
```json
{
  "id": "template_chicken_feed",
  "name": "Chicken Feed (50lb Bag)",
  "description": "Standard chicken layer feed",
  "item_defaults": {
    "title": "Chicken Layer Feed",
    "type": "feed",
    "unit": "pounds",
    "quantity": 50,
    "specs": {
      "feed_type": "layer",
      "animal": "chicken"
    },
    "custom_fields": {
      "storage_location": "Feed barn"
    },
    "tags": ["livestock", "chicken"]
  }
}
```

## Media Management

### Overview

Media files (pictures, documents) are stored in a `media/` subfolder at the folder level, keeping related files close to the items they belong to while allowing sharing across items in the same folder.

### Media Storage Location

Media is stored in each folder's `media/` subfolder:

```
inventory/
└── folders/
    ├── vehicles/
    │   ├── folder.json
    │   ├── media/                    # Media for all items in vehicles/
    │   │   ├── a1b2c3_honda_front.jpg
    │   │   ├── d4e5f6_honda_interior.jpg
    │   │   └── g7h8i9_toyota_receipt.pdf
    │   └── items/
    │       ├── item_honda/
    │       │   └── item.json         # References media/a1b2c3_honda_front.jpg
    │       └── item_toyota/
    │           └── item.json         # References media/g7h8i9_toyota_receipt.pdf
    └── tools/
        ├── folder.json
        ├── media/                    # Media for tools folder
        │   └── h1i2j3_drill.jpg
        └── items/
```

### Filename Format

**Pattern**: `{sha1_prefix}_{original_name}.{ext}`

- `{sha1_prefix}`: First 6 characters of SHA1 hash of file contents
- `{original_name}`: Original filename (sanitized, lowercase, underscores)
- `{ext}`: Original file extension (lowercase)

**Examples**:
```
media/
├── a1b2c3_front_view.jpg
├── d4e5f6_side_angle.jpg
├── g7h8i9_detail_closeup.png
├── j0k1l2_purchase_receipt.pdf
└── m3n4o5_user_manual.pdf
```

### Media Metadata in item.json

Items reference media files stored in the parent folder's `media/` directory:

```json
{
  "media": [
    {
      "filename": "a1b2c3_front_view.jpg",
      "hash": "a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0",
      "size": 2097152,
      "mime_type": "image/jpeg",
      "added_at": "2025-01-01T10:00:00Z",
      "caption": "Front view",
      "is_primary": true
    },
    {
      "filename": "j0k1l2_purchase_receipt.pdf",
      "hash": "j0k1l2m3n4o5p6q7r8s9t0u1v2w3x4y5z6a7b8c9",
      "size": 524288,
      "mime_type": "application/pdf",
      "added_at": "2025-01-01T10:05:00Z",
      "caption": "Purchase receipt"
    }
  ]
}
```

### Media Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `filename` | string | Yes | Filename in the media/ folder |
| `hash` | string | Yes | Full SHA1 hash of file contents |
| `size` | integer | Yes | File size in bytes |
| `mime_type` | string | Yes | MIME type of the file |
| `added_at` | ISO 8601 | Yes | When file was added |
| `caption` | string | No | Description of the media |
| `is_primary` | boolean | No | True if this is the main/thumbnail image |

### Supported Formats

**Images**:
- `image/jpeg` (JPG/JPEG)
- `image/png` (PNG)
- `image/webp` (WebP)
- `image/gif` (GIF)

**Documents** (for receipts, manuals, warranties):
- `application/pdf` (PDF)

**Videos** (optional, for equipment demos):
- `video/mp4` (MP4)
- `video/webm` (WebM)

### Size Limits

- Maximum file size: 10 MB per image, 50 MB per video
- Maximum files per item: 20
- Maximum total media per folder: 500 MB

### Benefits of Folder-Level Media

1. **Proximity**: Media stays close to related items
2. **Sharing**: Multiple items can reference the same media file
3. **Organization**: Easy to browse all media for a category
4. **Cleanup**: Easier to identify orphaned files
5. **Backup**: Simpler folder structure for syncing

## Multilanguage Support

### Supported Languages

The inventory collection supports 11 languages:
- English (EN)
- Portuguese (PT)
- Spanish (ES)
- French (FR)
- German (DE)
- Italian (IT)
- Dutch (NL)
- Polish (PL)
- Russian (RU)
- Chinese (ZH)
- Japanese (JA)

Language codes follow ISO 639-1 standard:
- `en` for English
- `pt` for Portuguese
- `es` for Spanish
- etc.

### Multilanguage Fields

The following fields support multiple languages:

**Folder Fields**:
- `name`: Folder display name
- `description`: Folder description

**Item Fields**:
- `title`: Item title
- `description`: Item description
- `notes`: Additional notes

**Template Fields**:
- `name`: Template display name
- `description`: Template description

### JSON Format for Translations

Use the `translations` object to provide content in multiple languages:

**Folder with Translations**:
```json
{
  "id": "folder_vehicles",
  "name": "Vehicles",
  "description": "All motorized vehicles",
  "translations": {
    "pt": {
      "name": "Veículos",
      "description": "Todos os veículos motorizados"
    },
    "es": {
      "name": "Vehículos",
      "description": "Todos los vehículos motorizados"
    },
    "fr": {
      "name": "Véhicules",
      "description": "Tous les véhicules motorisés"
    }
  }
}
```

**Item with Translations**:
```json
{
  "id": "item_20250101_abc123",
  "title": "Honda Civic 1999",
  "description": "Blue sedan in good condition",
  "translations": {
    "pt": {
      "title": "Honda Civic 1999",
      "description": "Sedan azul em bom estado"
    },
    "es": {
      "title": "Honda Civic 1999",
      "description": "Sedán azul en buen estado"
    }
  }
}
```

**Template with Translations**:
```json
{
  "id": "template_gasoline",
  "name": "Gasoline (Jerry Can)",
  "description": "20L gasoline for generators",
  "translations": {
    "pt": {
      "name": "Gasolina (Jerricã)",
      "description": "20L de gasolina para geradores"
    },
    "es": {
      "name": "Gasolina (Bidón)",
      "description": "20L de gasolina para generadores"
    }
  }
}
```

### Item Type Translations

Item types have display names that should be translated in the UI. The type catalog should include translations:

```json
{
  "car": {
    "id": "car",
    "category": "vehicles",
    "display_name": {
      "en": "Car",
      "pt": "Carro",
      "es": "Coche",
      "fr": "Voiture",
      "de": "Auto"
    }
  },
  "gasoline": {
    "id": "gasoline",
    "category": "fuel",
    "display_name": {
      "en": "Gasoline",
      "pt": "Gasolina",
      "es": "Gasolina",
      "fr": "Essence",
      "de": "Benzin"
    }
  }
}
```

### Measurement Unit Translations

Units should also be translated in the UI:

```json
{
  "liters": {
    "id": "liters",
    "symbol": "L",
    "display_name": {
      "en": "Liters",
      "pt": "Litros",
      "es": "Litros",
      "fr": "Litres",
      "de": "Liter"
    }
  },
  "kilograms": {
    "id": "kilograms",
    "symbol": "kg",
    "display_name": {
      "en": "Kilograms",
      "pt": "Quilogramas",
      "es": "Kilogramos",
      "fr": "Kilogrammes",
      "de": "Kilogramm"
    }
  }
}
```

### Language Fallback

When displaying content:
1. Try the user's preferred language
2. Fall back to English (en)
3. Fall back to the first available translation
4. Use the base field value if no translations exist

### UI Translation Keys

The inventory app requires the following translation keys in the language files:

**Collection Type**:
```json
{
  "collection_type_inventory": "Inventory",
  "collection_type_desc_inventory": "Track personal or shared inventories with folders, items, and borrowing management.",
  "collection_type_features_inventory": "Folder organization|Item tracking|Borrowing system|Usage tracking|Templates"
}
```

**Folder Management**:
```json
{
  "inventory_folder": "Folder",
  "inventory_folders": "Folders",
  "inventory_create_folder": "Create Folder",
  "inventory_folder_name": "Folder Name",
  "inventory_folder_description": "Folder Description",
  "inventory_parent_folder": "Parent Folder",
  "inventory_root_folder": "Root (No Parent)",
  "inventory_max_depth_reached": "Maximum folder depth reached (5 levels)"
}
```

**Item Management**:
```json
{
  "inventory_item": "Item",
  "inventory_items": "Items",
  "inventory_add_item": "Add Item",
  "inventory_edit_item": "Edit Item",
  "inventory_item_title": "Title",
  "inventory_item_type": "Type",
  "inventory_item_quantity": "Quantity",
  "inventory_item_unit": "Unit",
  "inventory_item_description": "Description",
  "inventory_date_purchased": "Date Purchased",
  "inventory_date_expired": "Expiration Date",
  "inventory_no_expiration": "No Expiration",
  "inventory_expired": "Expired",
  "inventory_expires_soon": "Expires Soon"
}
```

**Type Selection**:
```json
{
  "inventory_select_type": "Select Type",
  "inventory_search_types": "Search types...",
  "inventory_recent_types": "Recently Used",
  "inventory_all_types": "All Types",
  "inventory_type_other": "Other/Custom"
}
```

**Batches**:
```json
{
  "inventory_batch": "Batch",
  "inventory_batches": "Batches",
  "inventory_add_batch": "Add Batch",
  "inventory_batch_quantity": "Batch Quantity",
  "inventory_batch_expiry": "Batch Expiry",
  "inventory_batch_cost": "Cost",
  "inventory_batch_supplier": "Supplier"
}
```

**Usage Tracking**:
```json
{
  "inventory_usage": "Usage",
  "inventory_consume": "Consume",
  "inventory_refill": "Refill",
  "inventory_adjustment": "Adjustment",
  "inventory_usage_reason": "Reason",
  "inventory_usage_history": "Usage History",
  "inventory_current_quantity": "Current Quantity",
  "inventory_initial_quantity": "Initial Quantity"
}
```

**Borrowing**:
```json
{
  "inventory_borrow": "Borrow",
  "inventory_borrowed": "Borrowed",
  "inventory_borrowed_to": "Borrowed to",
  "inventory_borrowed_at": "Borrowed at",
  "inventory_return": "Return",
  "inventory_returned": "Returned",
  "inventory_expected_return": "Expected Return",
  "inventory_borrower": "Borrower",
  "inventory_borrower_callsign": "Callsign",
  "inventory_borrower_text": "Name/Description",
  "inventory_borrow_quantity": "Quantity to Borrow",
  "inventory_available_quantity": "Available"
}
```

**Templates**:
```json
{
  "inventory_template": "Template",
  "inventory_templates": "Templates",
  "inventory_create_template": "Create Template",
  "inventory_use_template": "Use Template",
  "inventory_template_name": "Template Name",
  "inventory_from_template": "Create from Template"
}
```

**Media**:
```json
{
  "inventory_media": "Media",
  "inventory_add_photo": "Add Photo",
  "inventory_add_document": "Add Document",
  "inventory_primary_photo": "Primary Photo",
  "inventory_caption": "Caption"
}
```

**Visibility**:
```json
{
  "inventory_visibility": "Visibility",
  "inventory_private": "Private",
  "inventory_group": "Shared with Groups",
  "inventory_public": "Public",
  "inventory_shared_groups": "Shared Groups"
}
```

## Visibility and Sharing

### Visibility Levels

#### Private (Default)
- Only the owner can view and edit
- Data not synced to stations unless explicitly shared
- Default for all new folders and items

```json
{
  "visibility": "private",
  "shared_groups": []
}
```

#### Group
- Owner and members of specified groups can view
- Groups are defined in the Groups collection
- Edit permissions remain with owner only

```json
{
  "visibility": "group",
  "shared_groups": ["group_family", "group_neighbors"]
}
```

#### Public
- Anyone can view
- Only owner can edit
- Syncs to connected stations

```json
{
  "visibility": "public",
  "shared_groups": []
}
```

### Visibility Inheritance

- Items inherit parent folder's visibility by default
- Items can override with more restrictive or more open visibility
- A private item in a public folder remains private
- A public item in a private folder is public (but folder itself hidden)

## Security Configuration

### metadata.json

Collection-level metadata stored at the inventory root.

```json
{
  "version": "1.0",
  "collection_id": "inventory",
  "collection_type": "inventory",
  "title": "My Inventory",
  "created_at": "2025-01-01T10:00:00Z",
  "modified_at": "2025-01-01T15:30:00Z",
  "owner_callsign": "X1ABCD",
  "owner_npub": "npub1...",
  "default_visibility": "private"
}
```

### extra/security.json

Security and permission settings.

```json
{
  "admin_npub": "npub1...",
  "admins": ["X1ABCD"],
  "moderators": {
    "folder_tools": ["Y2EFGH", "Z3IJKL"],
    "folder_food": ["A4MNOP"]
  },
  "default_visibility": "private",
  "allow_public_items": true,
  "require_signature": true
}
```

### Permission Levels

| Role | Can View | Can Edit | Can Delete | Can Moderate |
|------|----------|----------|------------|--------------|
| Owner | All | All | All | All |
| Admin | All | All | All | All |
| Moderator | Assigned folders | No | No | Assigned folders |
| Group Member | Shared items | No | No | No |
| Public | Public items | No | No | No |

## Complete Examples

### Example 1: Vehicle Item

**File**: `folders/vehicles/items/item_20250101_abc123/item.json`

```json
{
  "id": "item_20250101_abc123",
  "title": "Honda Civic 1999",
  "type": "car",
  "quantity": 1,
  "unit": "units",
  "description": "Blue sedan, daily driver. Regular maintenance, new tires in 2024.",
  "date_purchased": "2020-05-15",
  "date_expired": null,
  "visibility": "private",
  "shared_groups": [],
  "created_at": "2025-01-01T10:00:00Z",
  "modified_at": "2025-01-01T10:00:00Z",
  "owner_callsign": "X1ABCD",
  "media": [
    {
      "filename": "a1b2c3_front.jpg",
      "hash": "a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0",
      "size": 2097152,
      "mime_type": "image/jpeg",
      "added_at": "2025-01-01T10:00:00Z",
      "caption": "Front view",
      "is_primary": true
    },
    {
      "filename": "d4e5f6_interior.jpg",
      "hash": "d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0u1v2w3",
      "size": 1548576,
      "mime_type": "image/jpeg",
      "added_at": "2025-01-01T10:05:00Z",
      "caption": "Interior dashboard"
    }
  ],
  "specs": {
    "brand": "Honda",
    "model": "Civic",
    "year": 1999,
    "vin": "2HGCJ566X9H512345",
    "mileage": 185000,
    "fuel_type": "gasoline",
    "transmission": "manual",
    "color": "blue",
    "license_plate": "AB-12-CD",
    "insurance_expiry": "2025-06-30"
  },
  "custom_fields": {
    "garage_location": "Bay 3",
    "insurance_policy": "POL-12345",
    "last_oil_change": "2024-11-15"
  },
  "tags": ["daily-driver", "manual-transmission"],
  "notes": "Check brakes before winter. Needs new wiper blades.",
  "metadata": {
    "npub": "npub1abc123...",
    "signature": "sig_abc123..."
  }
}
```

### Example 2: Food Item with Multiple Batches (Stock Management)

**File**: `folders/food/pantry/items/item_20250101_def456/item.json`

This example shows how to track the same item with multiple batches having different expiration dates:

```json
{
  "id": "item_20250101_def456",
  "title": "Canned Tomatoes - San Marzano",
  "type": "canned_vegetables",
  "quantity": 30,
  "unit": "cans",
  "initial_quantity": 36,
  "current_quantity": 30,
  "description": "Organic San Marzano tomatoes, 28oz cans",
  "visibility": "group",
  "shared_groups": ["group_family"],
  "created_at": "2025-01-01T14:00:00Z",
  "modified_at": "2025-06-15T10:00:00Z",
  "owner_callsign": "X1ABCD",
  "batches": [
    {
      "id": "batch_001",
      "quantity": 18,
      "date_purchased": "2025-01-01",
      "date_expired": "2027-06-15",
      "cost": 36.00,
      "supplier": "Costco",
      "notes": "Case of 24, used 6"
    },
    {
      "id": "batch_002",
      "quantity": 12,
      "date_purchased": "2025-06-15",
      "date_expired": "2028-01-20",
      "cost": 28.00,
      "supplier": "Local grocery",
      "notes": "On sale"
    }
  ],
  "media": [
    {
      "filename": "e7f8g9_cans.jpg",
      "hash": "e7f8g9h0i1j2k3l4m5n6o7p8q9r0s1t2u3v4w5x6",
      "size": 1024000,
      "mime_type": "image/jpeg",
      "added_at": "2025-01-01T14:00:00Z",
      "is_primary": true
    }
  ],
  "specs": {
    "storage_temp": "room_temp",
    "organic": true,
    "calories_per_serving": 25,
    "allergens": []
  },
  "custom_fields": {
    "shelf_location": "Pantry A3"
  },
  "tags": ["pantry-staple", "italian-cooking"],
  "metadata": {
    "npub": "npub1abc123...",
    "signature": "sig_def456..."
  }
}
```

**File**: `folders/food/pantry/items/item_20250101_def456/usage.json`

```json
{
  "item_id": "item_20250101_def456",
  "events": [
    {
      "id": "usage_20250215_001",
      "type": "consume",
      "quantity": 3,
      "unit": "cans",
      "date": "2025-02-15T18:00:00Z",
      "batch_id": "batch_001",
      "reason": "Pasta sauce",
      "notes": "Sunday dinner"
    },
    {
      "id": "usage_20250401_001",
      "type": "consume",
      "quantity": 3,
      "unit": "cans",
      "date": "2025-04-01T12:00:00Z",
      "batch_id": "batch_001",
      "reason": "Soup",
      "notes": "Family gathering"
    },
    {
      "id": "usage_20250615_001",
      "type": "refill",
      "quantity": 12,
      "unit": "cans",
      "date": "2025-06-15T10:00:00Z",
      "batch_id": "batch_002",
      "cost": 28.00,
      "supplier": "Local grocery",
      "date_expired": "2028-01-20"
    }
  ]
}
```

### Example 3: Tool with Borrowing History

**File**: `folders/tools/power-tools/items/item_20250102_ghi789/item.json`

```json
{
  "id": "item_20250102_ghi789",
  "title": "DeWalt 20V Cordless Drill",
  "type": "drill",
  "quantity": 1,
  "unit": "units",
  "description": "Cordless drill with two batteries and charger",
  "date_purchased": "2023-03-15",
  "visibility": "private",
  "created_at": "2025-01-02T09:00:00Z",
  "modified_at": "2025-01-02T09:00:00Z",
  "owner_callsign": "X1ABCD",
  "media": [
    {
      "filename": "h1i2j3_drill.jpg",
      "hash": "h1i2j3k4l5m6n7o8p9q0r1s2t3u4v5w6x7y8z9a0",
      "size": 1536000,
      "mime_type": "image/jpeg",
      "added_at": "2025-01-02T09:00:00Z",
      "is_primary": true
    }
  ],
  "specs": {
    "brand": "DeWalt",
    "model": "DCD771C2",
    "condition": "good",
    "power_source": "battery",
    "voltage": 20,
    "warranty_until": "2026-03-15"
  },
  "custom_fields": {
    "storage_location": "Tool shed - pegboard",
    "includes": "2 batteries, charger, case"
  },
  "tags": ["power-tool", "cordless"],
  "metadata": {
    "npub": "npub1abc123...",
    "signature": "sig_ghi789..."
  }
}
```

**File**: `folders/tools/power-tools/items/item_20250102_ghi789/borrows.json`

```json
{
  "item_id": "item_20250102_ghi789",
  "borrows": [
    {
      "id": "borrow_20251211_001",
      "quantity": 1,
      "borrower_type": "callsign",
      "borrower_callsign": "Y2EFGH",
      "borrower_text": null,
      "borrowed_at": "2025-12-11T10:00:00Z",
      "expected_return": "2025-12-18T10:00:00Z",
      "returned_at": null,
      "notes": "Deck renovation project"
    },
    {
      "id": "borrow_20251001_001",
      "quantity": 1,
      "borrower_type": "text",
      "borrower_callsign": null,
      "borrower_text": "Neighbor Mike",
      "borrowed_at": "2025-10-01T14:00:00Z",
      "expected_return": "2025-10-08T14:00:00Z",
      "returned_at": "2025-10-05T16:30:00Z",
      "notes": "Returned early, good condition"
    }
  ]
}
```

### Example 4: Folder Structure

**File**: `folders/vehicles/folder.json`

```json
{
  "id": "folder_vehicles",
  "name": "Vehicles",
  "parent_id": null,
  "depth": 0,
  "description": "All motorized and non-motorized vehicles",
  "visibility": "private",
  "shared_groups": [],
  "icon": "car",
  "color": "#2196F3",
  "created_at": "2025-01-01T09:00:00Z",
  "modified_at": "2025-01-01T09:00:00Z",
  "owner_callsign": "X1ABCD",
  "metadata": {
    "npub": "npub1abc123...",
    "signature": "sig_folder_vehicles..."
  }
}
```

**File**: `folders/vehicles/cars/folder.json`

```json
{
  "id": "folder_vehicles_cars",
  "name": "Cars",
  "parent_id": "folder_vehicles",
  "depth": 1,
  "description": "Passenger vehicles",
  "visibility": "private",
  "shared_groups": [],
  "icon": "car",
  "color": "#2196F3",
  "created_at": "2025-01-01T09:05:00Z",
  "modified_at": "2025-01-01T09:05:00Z",
  "owner_callsign": "X1ABCD",
  "metadata": {
    "npub": "npub1abc123...",
    "signature": "sig_folder_cars..."
  }
}
```

### Example 5: Consumable Item with Usage Tracking (Gasoline)

**File**: `folders/fuel/items/item_20251101_gasoline/item.json`

```json
{
  "id": "item_20251101_gasoline",
  "title": "Gasoline Reserve",
  "type": "gasoline",
  "initial_quantity": 60,
  "current_quantity": 45.5,
  "quantity": 45.5,
  "unit": "liters",
  "description": "Gasoline stored in jerry cans for generator and equipment",
  "visibility": "private",
  "created_at": "2025-11-01T10:00:00Z",
  "modified_at": "2025-12-28T08:00:00Z",
  "owner_callsign": "X1ABCD",
  "batches": [
    {
      "id": "batch_001",
      "quantity": 5.5,
      "date_purchased": "2025-11-01",
      "date_expired": "2026-05-01",
      "cost": 35.00,
      "supplier": "Gas station A",
      "notes": "Older fuel, use first"
    },
    {
      "id": "batch_002",
      "quantity": 40,
      "date_purchased": "2025-12-20",
      "date_expired": "2026-06-20",
      "cost": 92.00,
      "supplier": "Gas station B",
      "notes": "Fresh stock"
    }
  ],
  "media": [
    {
      "filename": "k1l2m3_jerry_cans.jpg",
      "hash": "k1l2m3n4o5p6q7r8s9t0u1v2w3x4y5z6a7b8c9d0",
      "size": 1200000,
      "mime_type": "image/jpeg",
      "added_at": "2025-11-01T10:00:00Z",
      "caption": "Fuel storage area",
      "is_primary": true
    }
  ],
  "specs": {
    "octane_rating": 95,
    "fuel_type": "unleaded"
  },
  "custom_fields": {
    "storage_location": "Fuel shed",
    "stabilizer_added": true
  },
  "tags": ["fuel", "generator", "equipment"]
}
```

**File**: `folders/fuel/items/item_20251101_gasoline/usage.json`

```json
{
  "item_id": "item_20251101_gasoline",
  "events": [
    {
      "id": "usage_20251115_001",
      "type": "consume",
      "quantity": 4,
      "unit": "liters",
      "date": "2025-11-15T08:00:00Z",
      "batch_id": "batch_001",
      "reason": "Generator",
      "notes": "Power outage backup"
    },
    {
      "id": "usage_20251201_001",
      "type": "consume",
      "quantity": 2.5,
      "unit": "liters",
      "date": "2025-12-01T10:00:00Z",
      "batch_id": "batch_001",
      "reason": "Chainsaw",
      "notes": "Clearing fallen branches"
    },
    {
      "id": "usage_20251210_001",
      "type": "consume",
      "quantity": 8,
      "unit": "liters",
      "date": "2025-12-10T16:00:00Z",
      "batch_id": "batch_001",
      "reason": "Generator",
      "notes": "Extended power outage"
    },
    {
      "id": "usage_20251220_001",
      "type": "refill",
      "quantity": 40,
      "unit": "liters",
      "date": "2025-12-20T14:00:00Z",
      "batch_id": "batch_002",
      "cost": 92.00,
      "supplier": "Gas station B",
      "date_expired": "2026-06-20",
      "notes": "Restocked reserves"
    }
  ]
}
```

**Quantity Tracking**:
- Initial batch_001: 20L
- Consumed from batch_001: 4 + 2.5 + 8 = 14.5L
- Remaining batch_001: 5.5L
- Refilled batch_002: 40L
- Current total: 5.5 + 40 = 45.5L

## Parsing Implementation

### Reading Inventory Structure

1. Read `metadata.json` at collection root
2. Read templates from `templates/` directory
3. Scan `folders/` directory recursively (respecting max depth)
4. For each folder:
   - Read `folder.json`
   - Scan `media/` subfolder for media files
   - For each `items/` subfolder, read item folders
5. For each item folder:
   - Read `item.json`
   - Optionally read `borrows.json` (borrowing history)
   - Optionally read `usage.json` (consumption/refill events)

### Item Type Lookup

```dart
// Type catalog structure
class ItemType {
  final String id;
  final String displayName;
  final String category;
  final List<String> specFields;
}

// Lookup by ID
ItemType? getTypeById(String typeId) {
  return typeCatalog[typeId];
}

// Search types
List<ItemType> searchTypes(String query) {
  return typeCatalog.values
    .where((t) => t.displayName.toLowerCase().contains(query.toLowerCase()))
    .toList();
}

// Get types by category
List<ItemType> getTypesByCategory(String category) {
  return typeCatalog.values
    .where((t) => t.category == category)
    .toList();
}
```

### Available Quantity Calculation

```dart
int getAvailableQuantity(InventoryItem item, List<BorrowEvent> borrows) {
  final activeBorrows = borrows.where((b) => b.returnedAt == null);
  final borrowedQuantity = activeBorrows.fold(0, (sum, b) => sum + b.quantity);
  return item.quantity - borrowedQuantity;
}
```

## Validation Rules

### Folder Validation

- `id` must be unique within collection
- `name` must not be empty
- `depth` must be 0-5
- `parent_id` must reference existing folder (or null for root)
- `parent_id` folder must have depth < 5
- Folder name must be filesystem-safe when used as directory name

### Item Validation

- `id` must match pattern `item_{YYYYMMDD}_{random}`
- `title` must not be empty
- `type` must exist in type catalog (or be "other")
- `unit` must be a valid measurement unit
- `quantity` must be >= 0 (can be 0 if fully consumed)
- `date_purchased` must be valid date if present
- `date_expired` must be >= `date_purchased` if both present
- Media files must exist in parent folder's `media/` folder
- Batch quantities should sum to `current_quantity`

### Borrow Validation

- `quantity` must be > 0 and <= available quantity
- `borrower_type` must be "callsign" or "text"
- If `borrower_type` is "callsign", `borrower_callsign` is required
- If `borrower_type` is "text", `borrower_text` is required
- `returned_at` must be >= `borrowed_at` if present

### Usage Event Validation

- `id` must match pattern `usage_{YYYYMMDD}_{NNN}`
- `type` must be "consume", "refill", or "adjustment"
- `quantity` must be > 0 for consume/refill, any number for adjustment
- `unit` must match item's unit
- `date` must be valid ISO 8601 timestamp
- For consume: `quantity` must not exceed available quantity

## Best Practices

### For Users

**Organization**:
- Create logical folder hierarchy for your inventory
- Use consistent naming conventions
- Tag items for easy searching
- Keep quantity updated as items are used

**Media**:
- Add at least one photo per valuable item
- Include photos of serial numbers, receipts
- Attach PDF manuals and warranties when available
- Use clear, well-lit photos

**Usage Tracking**:
- Record consumption events as they happen
- Use batch tracking for items with expiration dates
- Follow FIFO (First In, First Out) for perishables
- Create templates for frequently added items

**Borrowing**:
- Always record who borrowed items
- Set expected return dates
- Mark items as returned promptly

**Expiration Tracking**:
- Set expiration dates for perishables
- Regularly review expiring items
- Use tags like "expires-soon" for alerts

### For Developers

**Type System**:
- Present types in searchable interface
- Show recently used types
- Allow custom "other" type

**Validation**:
- Enforce folder depth limits
- Validate quantity before borrow
- Check expiration dates for warnings

**Performance**:
- Cache folder structure
- Lazy-load item details
- Index for search functionality

## Related Documentation

### Geogram Core Documentation

- **[Collections Overview](../others/README.md)** - Introduction to collections system
- **[Groups Format](groups-format-specification.md)** - Group membership for sharing
- **[Security Model](../others/security-model.md)** - Cryptographic verification

### Related Collection Types

- **[Market](market-format-specification.md)** - Marketplace with similar item structure
- **[Places](places-format-specification.md)** - Geographic locations
- **[Blog](blog-format-specification.md)** - Folder-based blog posts

## Change Log

### Version 1.0 (2026-01-01)

Initial release of Inventory format specification.

**Features**:
- Folder-based organization (max 5 levels)
- Private by default visibility with group/public options
- Comprehensive item tracking with 200+ predefined types
- Type-specific field schemas
- Searchable type selection UI
- **Measurement units**: Comprehensive unit support (liters, kilograms, meters, units, etc.)
- **Batch/lot tracking**: Track multiple batches with different expiration dates for stock management
- **Usage tracking**: Record consumption and refill events with full history
- **Templates system**: Define item presets for quick creation of frequently added items
- **Media management**: Folder-level media storage for pictures and documents
- **Multilanguage support**: 11 languages with translations for titles, descriptions, types, and units
- Multiple borrow event tracking per item
- Custom fields support
- NOSTR cryptographic signatures
- Group sharing integration

---

**Document Version**: 1.0
**Last Updated**: 2026-01-01
**Maintained by**: Geogram Contributors
**License**: Apache 2.0
