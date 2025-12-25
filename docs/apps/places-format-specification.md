# Places Format Specification

**Version**: 1.4
**Last Updated**: 2025-12-24
**Status**: Active

## Table of Contents

- [Overview](#overview)
- [File Organization](#file-organization)
- [Coordinate-Based Organization](#coordinate-based-organization)
- [Place Format](#place-format)
- [Place Types Reference](#place-types-reference)
- [Location Radius](#location-radius)
- [Photos and Media](#photos-and-media)
- [Contributor Organization](#contributor-organization)
- [Reactions System](#reactions-system)
- [Comments](#comments)
- [Subfolder Organization](#subfolder-organization)
- [File Management](#file-management)
- [Permissions and Roles](#permissions-and-roles)
- [Moderation System](#moderation-system)
- [NOSTR Integration](#nostr-integration)
- [Complete Examples](#complete-examples)
- [Parsing Implementation](#parsing-implementation)
- [File Operations](#file-operations)
- [Validation Rules](#validation-rules)
- [Best Practices](#best-practices)
- [Security Considerations](#security-considerations)
- [Related Documentation](#related-documentation)
- [Change Log](#change-log)

## Overview

This document specifies the text-based format used for storing places information in the Geogram system. The places collection type provides a platform for documenting locations around the globe with photos, descriptions, and community engagement through likes and comments.

Places combine geographic organization with features similar to events, but focused on permanent or semi-permanent locations rather than time-based activities.

### Key Features

- **Coordinate-Based Organization**: Places organized by geographic regions
- **Compact Naming**: Simple region format `38.7_-9.1/` for efficiency
- **Grid System**: Globe divided into ~30,000 regions for efficient organization
- **Dense Region Support**: Automatic numbered subfolders (001/, 002/) when region exceeds 10,000 places
- **Unlimited Scalability**: Virtually unlimited capacity in dense urban areas
- **Precise Location**: Each place has specific coordinates with configurable radius
- **Radius Range**: 10 meters to 1 kilometer coverage area
- **Unlimited Media**: Any number of photos, videos, and files
- **Photo Reactions**: Individual likes and comments on each photo
- **Place Reactions**: Place-level feedback stored under `feedback/` (centralized API)
- **Contributor System**: Users can submit photos with attribution
- **Admin Moderation**: Admins can approve/reject/move contributor content
- **Subfolder Structure**: Optional subfolders for organizing content
- **Simple Text Format**: Plain text descriptions (no markdown)
- **NOSTR Integration**: Cryptographic signatures for authenticity

## File Organization

### Directory Structure

```
collection_name/
└── places/
    ├── 38.7_-9.1/                      # Region folder (1° precision)
    │   ├── 38.7223_-9.1393_cafe-landmark/
    │   │   ├── place.txt
    │   │   ├── photo1.jpg
    │   │   ├── photo2.jpg
    │   │   ├── exterior/
    │   │   │   ├── subfolder.txt
    │   │   │   ├── front-view.jpg
    │   │   │   └── side-view.jpg
    │   │   ├── contributors/
    │   │   │   ├── CR7BBQ/
    │   │   │   │   ├── contributor.txt
    │   │   │   │   ├── sunset-photo.jpg
    │   │   │   │   └── night-view.jpg
    │   │   │   └── X135AS/
    │   │   │       ├── contributor.txt
    │   │   │       └── drone-view.jpg
    │   │   ├── feedback/               # Place-level feedback (centralized)
    │   │   │   ├── likes.txt
    │   │   │   └── comments/
    │   │   └── .reactions/
    │   │       ├── place.txt
    │   │       ├── photo1.jpg.txt
    │   │       ├── photo2.jpg.txt
    │   │       ├── exterior.txt
    │   │       └── contributors/CR7BBQ.txt
    │   └── 38.7169_-9.1399_famous-tower/
    │       ├── place.txt
    │       ├── main-view.jpg
    │       └── .reactions/
    │           └── place.txt
    ├── 40.7_-74.0/                     # Another region
    │   └── 40.7128_-74.0060_central-park/
    │       ├── place.txt
    │       └── park-entrance.jpg
    └── 35.6_139.6/                     # Dense region example (Tokyo)
        ├── 001/                        # First 10,000 places
        │   ├── 35.6762_139.6503_tokyo-tower/
        │   │   └── place.txt
        │   └── 35.6895_139.6917_imperial-palace/
        │       └── place.txt
        └── 002/                        # Next 10,000 places
            └── 35.6812_139.7671_tokyo-skytree/
                └── place.txt
```

### Centralized Feedback (Place-Level)

Place-level likes/comments are stored under `feedback/` and should use the common feedback API (`/api/feedback/place/{placeId}/...`). Per-photo or per-subfolder reactions remain in `.reactions/` until those structures are migrated.

### Region Folder Naming

**Pattern**: `{LAT}_{LON}/`

**Coordinate Rounding**:
- Round latitude to 1 decimal place (e.g., 38.7223 → 38.7)
- Round longitude to 1 decimal place (e.g., -9.1393 → -9.1)
- This creates ~30,000 possible regions globally
- Each region covers approximately 130 km × 130 km at the equator

**Examples**:
```
38.7_-9.1/          # Lisbon area, Portugal
40.7_-74.0/         # New York City area, USA
51.5_-0.1/          # London area, UK
-33.8_151.2/        # Sydney area, Australia
35.6_139.6/         # Tokyo area, Japan
```

**Region Characteristics**:
- Approximately 1.04° latitude coverage
- Approximately 2.08° longitude coverage (at equator)
- Total regions: ~30,000 worldwide
- Each region size: ~130 km × 130 km (~17,000 km²)
- Automatic creation when first place added to region

### Dense Region Organization

For regions with many places (e.g., dense urban areas), the system uses numbered subfolders to maintain performance:

**Threshold**: 10,000 places per folder

**Structure**:
```
35.6_139.6/                 # Tokyo region (dense)
├── 001/                    # Places 1-10,000
│   ├── place1/
│   ├── place2/
│   └── ...
├── 002/                    # Places 10,001-20,000
│   ├── place10001/
│   └── ...
└── 003/                    # Places 20,001-30,000
    └── ...
```

**Subfolder Naming**:
- Format: `001/`, `002/`, `003/`, etc.
- Three-digit zero-padded numbers
- Sequential ordering
- Created automatically when threshold reached

**Migration Process**:
```
1. Region has < 10,000 places: Places directly in region folder
   38.7_-9.1/
   ├── place1/
   └── place2/

2. Region reaches 10,000 places: Create 001/ subfolder
   38.7_-9.1/
   └── 001/
       ├── place1/       # Moved from parent
       ├── place2/       # Moved from parent
       └── ...           # All 10,000 places

3. Region reaches 10,001+ places: Create 002/ subfolder
   38.7_-9.1/
   ├── 001/              # First 10,000 places
   └── 002/              # New places go here
       └── place10001/
```

**Benefits**:
- Simple structure for sparse regions (no subfolders needed)
- Scales to handle dense urban areas (millions of places possible)
- Maintains filesystem performance (max 10,000 items per folder)
- Predictable and algorithm-based organization

**Maximum Capacity**:
- Without subfolders: 10,000 places per region
- With subfolders: Virtually unlimited (999 × 10,000 = ~10 million places per region)
- Global theoretical maximum: ~30,000 regions × 10 million = 300 billion places

### Place Folder Naming

**Pattern**: `{LAT}_{LON}_{sanitized-name}/`

**Full Precision Coordinates**:
- Use full precision (6 decimal places recommended)
- Latitude: -90.0 to +90.0
- Longitude: -180.0 to +180.0

**Sanitization Rules**:
1. Convert name to lowercase
2. Replace spaces and underscores with single hyphens
3. Remove all non-alphanumeric characters (except hyphens)
4. Collapse multiple consecutive hyphens
5. Remove leading/trailing hyphens
6. Truncate to 50 characters
7. Prepend full coordinates

**Examples**:
```
Name: "Historic Café Landmark"
Coordinates: 38.7223, -9.1393
→ 38.7223_-9.1393_historic-cafe-landmark/

Name: "Central Park @ New York City"
Coordinates: 40.7128, -74.0060
→ 40.7128_-74.0060_central-park-new-york-city/

Name: "Tower Bridge"
Coordinates: 51.5055, -0.0754
→ 51.5055_-0.0754_tower-bridge/
```

### Special Directories

**`.reactions/` Directory**:
- Hidden directory (starts with dot)
- Contains reaction files for place and items
- One file per item that has likes/comments
- Filename matches target item with `.txt` suffix

**`.hidden/` Directory** (see Moderation System):
- Hidden directory for moderated content
- Contains files/comments hidden by moderators
- Not visible in standard UI

## Coordinate-Based Organization

### Grid System Overview

The places collection uses a two-level coordinate-based organization:

1. **Region Level**: Rounded coordinates (1 decimal place)
   - Purpose: Group nearby places into manageable folders
   - Limit: ~30,000 regions globally
   - Size: ~130 km × 130 km per region

2. **Place Level**: Full precision coordinates (6 decimals)
   - Purpose: Exact location identification
   - Precision: ~0.1 meters (at equator)
   - Unique: Each place has unique coordinates

### Coordinate Precision

**Region Coordinates** (1 decimal place):
```
Latitude:  38.7  (rounded from 38.7223)
Longitude: -9.1  (rounded from -9.1393)
Range: ±0.05° from center
Coverage: ~11 km × ~11 km (at mid-latitudes)
```

**Place Coordinates** (6 decimal places):
```
Latitude:  38.7223  (precise)
Longitude: -9.1393  (precise)
Precision: ~0.1 meters
```

### Finding a Place's Region

```
Given coordinates: 38.7223, -9.1393

1. Round latitude to 1 decimal: 38.7223 → 38.7
2. Round longitude to 1 decimal: -9.1393 → -9.1
3. Format region folder: 38.7_-9.1/
4. Check place count in region:
   - If < 10,000: Place folder goes directly in region folder
   - If ≥ 10,000: Place folder goes in appropriate numbered subfolder
5. Place created in: 38.7_-9.1/38.7223_-9.1393_cafe-landmark/
   or: 38.7_-9.1/001/38.7223_-9.1393_cafe-landmark/
```

### Region Distribution

**Global Coverage**:
- Latitude divisions: 180° / 1.04° ≈ 173 regions
- Longitude divisions: 360° / 2.08° ≈ 173 regions
- Total regions: 173 × 173 ≈ 30,000

**Region Examples by Continent**:
- Europe: ~1,500 regions
- Asia: ~9,000 regions
- Africa: ~6,000 regions
- North America: ~5,000 regions
- South America: ~3,500 regions
- Oceania: ~2,000 regions
- Antarctica: ~3,000 regions (mostly unpopulated)

### Benefits of Coordinate Organization

1. **Scalability**: Fixed number of regions (30,000 max)
2. **Geographic Clustering**: Nearby places grouped together
3. **Efficient Searching**: Navigate by coordinates directly
4. **No Hierarchy**: Flat structure within each region
5. **Global Coverage**: Works for any location on Earth
6. **Predictable**: Algorithm-based, no manual categorization

## Place Format

### Main Place File

Every place must have a `place.txt` file in the place folder root.

**Complete Structure (Single Language)**:
```
# PLACE: Place Name

CREATED: YYYY-MM-DD HH:MM_ss
AUTHOR: CALLSIGN
COORDINATES: lat,lon
RADIUS: meters
ADDRESS: Full Address (optional)
TYPE: category (optional)
FOUNDED: year or century (optional)
HOURS: Opening hours (optional)
ADMINS: npub1abc123..., npub1xyz789... (optional)
MODERATORS: npub1delta..., npub1echo... (optional)

Place description goes here.
Simple plain text format.
No markdown formatting.

Can include multiple paragraphs.
Each paragraph separated by blank line.

HISTORY (optional):
Historical information about the place.
Can include multiple paragraphs.

--> npub: npub1...
--> signature: hex_signature
```

**Complete Structure (Multilanguage)**:
```
# PLACE_EN: Place Name in English
# PLACE_PT: Nome do Local em Português
# PLACE_ES: Nombre del Lugar en Español

CREATED: YYYY-MM-DD HH:MM_ss
AUTHOR: CALLSIGN
COORDINATES: lat,lon
RADIUS: meters
ADDRESS: Full Address (optional)
TYPE: category (optional)
FOUNDED: year or century (optional)
HOURS: Opening hours (optional)
ADMINS: npub1abc123..., npub1xyz789... (optional)
MODERATORS: npub1delta..., npub1echo... (optional)

[EN]
Place description in English.
Multiple paragraphs allowed.

[PT]
Descrição do local em Português.
Vários parágrafos permitidos.

[ES]
Descripción del lugar en Español.
Se permiten múltiples párrafos.

HISTORY_EN:
Historical information in English.

HISTORY_PT:
Informação histórica em Português.

HISTORY_ES:
Información histórica en Español.

--> npub: npub1...
--> signature: hex_signature
```

### Header Section

1. **Title Line** (required)
   - **Single Language Format**: `# PLACE: <name>`
   - **Multilanguage Format**: `# PLACE_XX: <name>`
     - XX = two-letter language code in uppercase (EN, PT, ES, FR, DE, IT, NL, RU, ZH, JA, AR)
   - **Examples**:
     - Single: `# PLACE: Historic Café Landmark`
     - Multi: `# PLACE_EN: Historic Café Landmark`
     - Multi: `# PLACE_PT: Café Histórico Emblemático`
   - **Constraints**: Any length, but truncated in folder name
   - **Fallback**: Requested language → English (EN) → First available
   - **Note**: At least one language title required

2. **Blank Line** (required)
   - Separates title from metadata

3. **Created Timestamp** (required)
   - **Format**: `CREATED: YYYY-MM-DD HH:MM_ss`
   - **Example**: `CREATED: 2025-11-21 10:00_00`
   - **Note**: Underscore before seconds

4. **Author Line** (required)
   - **Format**: `AUTHOR: <callsign>`
   - **Example**: `AUTHOR: CR7BBQ`
   - **Constraints**: Alphanumeric callsign
   - **Note**: Author is automatically an admin

5. **Coordinates** (required)
   - **Format**: `COORDINATES: <lat>,<lon>`
   - **Example**: `COORDINATES: 38.7223,-9.1393`
   - **Constraints**: Valid lat,lon coordinates
   - **Precision**: Up to 6 decimal places recommended

6. **Radius** (required)
   - **Format**: `RADIUS: <meters>`
   - **Example**: `RADIUS: 5`
   - **Constraints**: 1 to 1000 meters
   - **Purpose**: Defines the area covered by this place
   - **Default**: 5 meters for precise locations

7. **Type** (required)
   - **Format**: `TYPE: <category>`
   - **Examples**: `TYPE: restaurant`, `TYPE: monument`, `TYPE: park`
   - **Purpose**: Categorize place for filtering/searching
   - **Note**: See [Place Types Reference](#place-types-reference) for comprehensive list

8. **Address** (optional)
   - **Format**: `ADDRESS: <full address>`
   - **Example**: `ADDRESS: 123 Main Street, Lisbon, Portugal`
   - **Purpose**: Human-readable location description

9. **Founded** (optional)
   - **Format**: `FOUNDED: <year or century>`
   - **Examples**:
     - Specific year: `FOUNDED: 1782`
     - Century: `FOUNDED: 12th century`
     - Approximate: `FOUNDED: circa 1500`
     - Era: `FOUNDED: Roman era`
   - **Purpose**: Indicate when place was established/built
   - **Note**: Especially useful for historic monuments and buildings

10. **Hours** (optional)
   - **Format**: `HOURS: <operating hours>`
   - **Examples**:
     - `HOURS: Mon-Fri 9:00-17:00, Sat-Sun 10:00-16:00`
     - `HOURS: Daily 8:00-20:00`
     - `HOURS: 24/7`
     - `HOURS: Seasonal (Apr-Oct)`
   - **Purpose**: Indicate when place is open/accessible
   - **Note**: Format is flexible, use human-readable text

11. **Admins** (optional)
   - **Format**: `ADMINS: <npub1>, <npub2>, ...`
   - **Example**: `ADMINS: npub1abc123..., npub1xyz789...`
   - **Purpose**: Additional administrators for place
   - **Note**: Author is always admin, even if not listed

12. **Moderators** (optional)
    - **Format**: `MODERATORS: <npub1>, <npub2>, ...`
    - **Example**: `MODERATORS: npub1delta..., npub1echo...`
    - **Purpose**: Users who can moderate content

13. **Blank Line** (required)
    - Separates header from content

### Content Section

The content section contains the place description.

**Single Language Format**:
```
Description text here.
Multiple paragraphs allowed.

Each paragraph separated by blank line.
```

**Multilanguage Format**:
```
[EN]
Description in English.
Multiple paragraphs allowed.

[PT]
Descrição em Português.
Vários parágrafos permitidos.

[ES]
Descripción en Español.
Se permiten múltiples párrafos.
```

**Language Codes**:
- **EN**: English
- **PT**: Português (Portuguese)
- **ES**: Español (Spanish)
- **FR**: Français (French)
- **DE**: Deutsch (German)
- **IT**: Italiano (Italian)
- **NL**: Nederlands (Dutch)
- **RU**: Русский (Russian)
- **ZH**: 中文 (Chinese)
- **JA**: 日本語 (Japanese)
- **AR**: العربية (Arabic)

**Characteristics**:
- **Plain text only** (no markdown)
- Multiple paragraphs allowed per language
- Blank lines separate paragraphs
- Whitespace preserved
- No length limit (reasonable sizes recommended)
- At least one language required
- Language blocks marked with `[XX]` where XX is the language code

**Fallback Behavior**:
1. Display content in requested language
2. If not available, fall back to English (EN)
3. If English not available, use first available language

### History Section

The optional HISTORY section provides historical context about the place.

**Single Language Format**:
```
HISTORY:
Historical information about the place.

Can include multiple paragraphs describing the history,
important events, architectural changes, and cultural
significance of the location.
```

**Multilanguage Format**:
```
HISTORY_EN:
Historical information in English.

HISTORY_PT:
Informação histórica em Português.

HISTORY_ES:
Información histórica en Español.
```

**Characteristics**:
- **Completely optional**: Not all places need historical context
- **Format**: `HISTORY:` for single language, `HISTORY_XX:` for multilanguage
- **Position**: After content section, before metadata
- **Plain text only** (no markdown)
- **Multiple paragraphs allowed**
- **Especially useful for**:
  - Historic monuments and buildings
  - Archaeological sites
  - Cultural landmarks
  - Places with significant events
  - Heritage sites

**When to Use**:
- Use FOUNDED field for establishment date
- Use HISTORY section for detailed historical context
- Separate from main description to allow focused historical information

**Example**:
```
HISTORY:
Originally built as a monastery in the 12th century, this
building served religious purposes until the dissolution in 1834.

It was later converted into a café in 1856 by José Silva,
who preserved much of the original architecture while
adapting the interior for commercial use.

The café became famous in the early 20th century as a meeting
place for Portuguese writers and intellectuals, including
Fernando Pessoa and Almada Negreiros.
```

### Place Metadata

Metadata appears after content and history sections:

```
--> npub: npub1abc123...
--> signature: hex_signature_string...
```

- **npub**: NOSTR public key (optional)
- **signature**: NOSTR signature, must be last if present

## Place Types Reference

### Overview

The TYPE field in a place allows categorization for filtering and searching. This reference provides a comprehensive list of recommended place types organized by category. Types are lowercase with hyphens separating words.

### Emergency & Off-Grid Survival

Critical resources for emergency and off-grid situations:
- **water-spring**: Natural spring or water source
- **well**: Water well (active or historic)
- **shelter**: Emergency shelter or refuge
- **cave**: Natural cave suitable for shelter
- **fire-tower**: Fire lookout tower
- **emergency-station**: Emergency services station
- **first-aid-station**: First aid post
- **rescue-point**: Designated rescue location
- **safety-point**: Safe gathering point
- **evacuation-point**: Emergency evacuation location
- **radio-tower**: Communication tower
- **ham-radio-repeater**: Amateur radio repeater station
- **weather-station**: Meteorological station
- **off-grid-settlement**: Off-grid community
- **survival-cache**: Emergency supply cache
- **bunker**: Underground shelter

### Nature & Wilderness

Natural features and wilderness areas:
- **mountain-peak**: Mountain summit
- **viewpoint**: Scenic overlook
- **waterfall**: Natural waterfall
- **lake**: Natural or man-made lake
- **river**: River or stream
- **beach**: Beach area
- **cliff**: Cliff face or escarpment
- **canyon**: Canyon or gorge
- **forest**: Forest or woodland area
- **wetland**: Wetland or marsh
- **hot-spring**: Natural hot spring
- **geyser**: Active geyser
- **volcano**: Volcanic feature
- **glacier**: Glacier or ice field
- **desert**: Desert area

### Fruit Trees

Specific fruit-bearing trees for foraging and survival:
- **apple-tree**: Apple tree
- **pear-tree**: Pear tree
- **cherry-tree**: Cherry tree
- **plum-tree**: Plum tree
- **peach-tree**: Peach tree
- **apricot-tree**: Apricot tree
- **fig-tree**: Fig tree
- **olive-tree**: Olive tree
- **orange-tree**: Orange tree
- **lemon-tree**: Lemon tree
- **lime-tree**: Lime tree
- **grapefruit-tree**: Grapefruit tree
- **pomegranate-tree**: Pomegranate tree
- **persimmon-tree**: Persimmon tree
- **mulberry-tree**: Mulberry tree
- **quince-tree**: Quince tree
- **medlar-tree**: Medlar tree
- **loquat-tree**: Loquat tree
- **avocado-tree**: Avocado tree
- **mango-tree**: Mango tree
- **papaya-tree**: Papaya tree
- **guava-tree**: Guava tree
- **passion-fruit-vine**: Passion fruit vine
- **grape-vine**: Grape vine
- **kiwi-vine**: Kiwi fruit vine
- **date-palm**: Date palm tree
- **coconut-palm**: Coconut palm tree

### Edible Plants & Vegetables

Wild and cultivated edible plants for foraging:
- **berry-bush**: General berry bush
- **blackberry-bush**: Blackberry bush
- **raspberry-bush**: Raspberry bush
- **blueberry-bush**: Blueberry bush
- **strawberry-patch**: Wild strawberry patch
- **elderberry-bush**: Elderberry bush
- **rosehip-bush**: Rose hip bush
- **wild-garlic-patch**: Wild garlic area
- **nettle-patch**: Stinging nettle patch (edible when cooked)
- **dandelion-patch**: Dandelion patch (edible greens)
- **wild-asparagus**: Wild asparagus
- **mushroom-spot**: Mushroom foraging location
- **herb-garden**: Herb garden
- **vegetable-garden**: Vegetable garden
- **community-garden**: Community garden plot
- **wild-onion-patch**: Wild onion area
- **wild-carrot-patch**: Wild carrot (Queen Anne's lace)
- **watercress-stream**: Watercress growing area
- **wild-mint-patch**: Wild mint area
- **wild-thyme-patch**: Wild thyme area
- **wild-oregano-patch**: Wild oregano area
- **chicory-patch**: Wild chicory
- **wild-fennel-patch**: Wild fennel
- **purslane-patch**: Purslane (edible succulent)
- **lamb's-quarters-patch**: Lamb's quarters (wild spinach)

### Nut Trees & Bushes

Nut-bearing trees and bushes:
- **walnut-tree**: Walnut tree
- **chestnut-tree**: Chestnut tree
- **hazelnut-bush**: Hazelnut bush
- **almond-tree**: Almond tree
- **pistachio-tree**: Pistachio tree
- **pecan-tree**: Pecan tree
- **pine-nut-tree**: Pine tree with edible pine nuts
- **acorn-oak**: Oak tree with edible acorns

### Agriculture & Farming

Agricultural facilities and farmland:
- **farm**: General farm
- **orchard**: Fruit orchard
- **vineyard**: Grape vineyard
- **greenhouse**: Greenhouse facility
- **barn**: Farm barn
- **silo**: Grain silo
- **windmill**: Historic or functioning windmill
- **irrigation-system**: Irrigation infrastructure
- **crop-field**: Crop field
- **pasture**: Grazing pasture
- **dairy-farm**: Dairy farm
- **ranch**: Livestock ranch
- **farmstand**: Farm produce stand
- **agricultural-cooperative**: Farming cooperative
- **seed-bank**: Seed storage facility

### Food & Drink

Food and beverage establishments:
- **restaurant**: Full-service restaurant
- **cafe**: Café or coffee shop
- **bar**: Bar or pub
- **fast-food**: Fast food restaurant
- **bakery**: Bakery
- **ice-cream-shop**: Ice cream parlor
- **brewery**: Brewery
- **winery**: Wine producer
- **food-truck**: Mobile food vendor location
- **tea-house**: Tea house

### Retail & Commerce

Shopping and commercial establishments:
- **shop**: General shop or store
- **shopping**: Shopping center or area
- **supermarket**: Large grocery store
- **market**: Market or bazaar
- **grocery-store**: Grocery store
- **convenience-store**: Convenience store
- **department-store**: Department store
- **bookstore**: Bookstore
- **pharmacy**: Pharmacy or drugstore
- **gas-station**: Gas/petrol station

### Accommodation

Lodging and accommodation:
- **hotel**: Hotel
- **hostel**: Hostel or budget accommodation
- **motel**: Motel
- **guesthouse**: Guest house or bed & breakfast
- **campground**: Camping area
- **caravan-park**: RV/caravan park
- **resort**: Resort facility
- **vacation-rental**: Vacation rental property

### Cultural & Historic

Cultural sites and historic landmarks:
- **monument**: Monument or memorial
- **statue**: Statue or sculpture
- **museum**: Museum
- **art-gallery**: Art gallery
- **historic-site**: Historic landmark
- **archaeological-site**: Archaeological excavation
- **castle**: Castle or fortress
- **palace**: Palace
- **temple**: Temple or shrine
- **church**: Christian church
- **mosque**: Islamic mosque
- **synagogue**: Jewish synagogue
- **cathedral**: Cathedral
- **monastery**: Monastery or abbey
- **ruins**: Historic ruins
- **ancient-tree**: Historic or ancient tree
- **commemorative-plaque**: Memorial plaque
- **cultural-center**: Cultural center

### Tourism & Attractions

Tourist destinations and attractions:
- **tourist-attraction**: General tourist site
- **theme-park**: Amusement or theme park
- **zoo**: Zoological park
- **aquarium**: Aquarium
- **botanical-garden**: Botanical garden
- **observatory**: Observatory (astronomical)
- **lighthouse**: Lighthouse
- **scenic-route**: Scenic driving/hiking route
- **visitor-center**: Tourist information center
- **landmark**: Notable landmark
- **geocache**: Geocaching location

### Urban Infrastructure

Urban facilities and infrastructure:
- **building**: General building
- **skyscraper**: High-rise building
- **tower**: Tower structure
- **bridge**: Bridge
- **tunnel**: Tunnel
- **dam**: Dam or reservoir
- **power-plant**: Power generation facility
- **water-treatment**: Water treatment facility
- **waste-facility**: Waste management facility
- **telecommunications-tower**: Cell/telecom tower
- **parking**: Parking facility
- **parking-lot**: Parking lot
- **street-art**: Street art or mural
- **fountain**: Fountain or water feature
- **clock-tower**: Clock tower
- **school**: Educational institution

### Recreation & Sports

Recreational facilities and sports venues:
- **park**: Public park
- **playground**: Playground
- **sports-field**: Sports field or pitch
- **stadium**: Stadium or arena
- **gym**: Fitness center
- **swimming-pool**: Public swimming pool
- **skate-park**: Skateboard park
- **golf-course**: Golf course
- **tennis-court**: Tennis court
- **climbing-area**: Rock climbing area
- **geocache**: Geocaching location

### Public Spaces

Public gathering areas:
- **plaza**: Public plaza or square
- **town-square**: Town square
- **amphitheater**: Outdoor amphitheater
- **garden**: Public garden
- **courtyard**: Public courtyard
- **promenade**: Waterfront promenade
- **boardwalk**: Wooden boardwalk

### Transportation

Transportation facilities and stops:
- **airport**: Airport
- **train-station**: Railway station
- **bus-station**: Bus terminal
- **bus-stop**: Local bus stop
- **bus-stop-long-distance**: Long-distance bus stop
- **metro-station**: Subway/metro station
- **ferry-terminal**: Ferry terminal
- **port**: Seaport or harbor
- **helipad**: Helicopter landing pad

### Services

Service facilities:
- **hospital**: Hospital or medical center
- **clinic**: Medical clinic
- **police-station**: Police station
- **fire-station**: Fire station
- **post-office**: Post office
- **library**: Public library
- **bank**: Bank

### Miscellaneous

Other place types:
- **office**: Office building or complex
- **factory**: Manufacturing facility
- **warehouse**: Warehouse or storage
- **cemetery**: Cemetery or graveyard
- **pet-cemetery**: Pet cemetery
- **rest-area**: Highway rest area
- **charging-station**: Electric vehicle charging station

### Usage Guidelines

**Choosing a Type**:
- Select the most specific applicable type
- Use lowercase with hyphens
- Keep types consistent across similar places
- Create new types when needed (follow naming convention)

**Examples**:
```
TYPE: water-spring
TYPE: apple-tree
TYPE: museum
TYPE: bus-stop-long-distance
TYPE: geocache
```

**Custom Types**:
- You can create custom types not in this list
- Follow naming convention: lowercase-with-hyphens
- Be descriptive and specific
- Document custom types for your collection

## Location Radius

### Radius Purpose

The radius defines the geographic coverage area of the place:
- **Small radius** (10-50m): Specific building, monument, or feature
- **Medium radius** (50-250m): Complex of buildings, park area
- **Large radius** (250-1000m): Large park, campus, neighborhood feature

### Radius Constraints

**Minimum**: 1 meter
- Very precise locations (trees, signs, small features)
- Fruit trees and small natural features
- Specific points of interest

**Default**: 5 meters
- Small features like statues, fountains
- Single buildings
- Specific landmarks

**Maximum**: 1000 meters (1 kilometer)
- Large parks
- Campus areas
- Neighborhood districts
- Mountain peaks with hiking areas

**Format**: Integer value in meters
```
RADIUS: 1       # Minimum (very precise)
RADIUS: 5       # Default (precise locations)
RADIUS: 50      # Small
RADIUS: 200     # Medium
RADIUS: 500     # Large
RADIUS: 1000    # Maximum
```

### Radius Use Cases

**1-10 meters**:
- Fruit trees and plants
- Small signs and markers
- Individual features

**10-50 meters**:
- Restaurants and cafes
- Shops and stores
- Monuments and statues
- Historic buildings
- Fountains
- Street art

**50-250 meters**:
- Small parks
- Shopping complexes
- Museum complexes
- University buildings
- Plazas and squares

**250-1000 meters**:
- Large parks
- Campuses
- Beaches
- Lakes
- Mountain summits
- Historic districts
- Natural features

### Radius Display

**UI Considerations**:
- Display circle on map with specified radius
- Show coverage area visually
- Help users understand geographic extent
- Use for proximity searches ("places near me")
- Filter overlapping places

## Photos and Media

### Photo Organization

Photos can be stored:
1. In the `images/` subfolder (recommended, standard location)
2. Directly in place folder (legacy support)
3. In thematic subfolders (organized by category)
4. In contributor folders (user submissions)

**Standard Structure (images/ folder)**:
```
38.7223_-9.1393_cafe-landmark/
├── place.txt
├── images/                 # Standard photo location
│   ├── photo1.jpg          # Sequential naming
│   ├── photo2.jpg
│   ├── photo3.png
│   └── photo4.webp
├── exterior/               # Thematic subfolder
│   ├── subfolder.txt
│   ├── front-view.jpg
│   └── side-view.jpg
└── contributors/           # User submissions
    └── CR7BBQ/
        ├── contributor.txt
        ├── sunset-photo.jpg
        └── night-view.jpg
```

**Legacy Structure (direct in folder)**:
```
38.7223_-9.1393_cafe-landmark/
├── place.txt
├── main-entrance.jpg       # Direct photos (legacy)
├── interior.jpg
├── menu-board.jpg
└── contributors/
    └── CR7BBQ/
        └── sunset-photo.jpg
```

### Supported Media Types

**Images**:
- JPG, JPEG, PNG, GIF, WebP, BMP
- Recommended: JPG for photos, PNG for graphics
- Any resolution (high resolution recommended)

**Videos**:
- MP4, AVI, MOV, WebM
- Recommended: MP4 for compatibility
- Short clips preferred (under 2 minutes)

**Documents**:
- PDF, TXT, MD
- Information brochures, maps, guides

### Individual Photo Reactions

Each photo can have its own likes and comments:

**Reaction File**: `.reactions/photo-name.jpg.txt`

**Format**:
```
LIKES: CR7BBQ, X135AS, BRAVO2

> 2025-11-21 14:00_00 -- CR7BBQ
Beautiful composition! Love the lighting.
--> npub: npub1abc...
--> signature: hex_sig

> 2025-11-21 15:30_00 -- X135AS
This angle really captures the architecture.
```

### Photo Metadata (Optional)

Photos can have associated metadata files:

**File**: `photo-name.jpg.txt` (in same directory)

```
PHOTOGRAPHER: CR7BBQ
TAKEN: 2025-11-21
CAMERA: Sony A7IV
SETTINGS: f/2.8, 1/250s, ISO 400
DESCRIPTION: View from the main entrance during golden hour
```

## Contributor Organization

### Overview

Places can have multiple contributors who share photos and information. Each contributor gets their own subfolder identified by their callsign, allowing clear attribution and organization of contributed content.

### Contributor Folder Structure

```
places/
└── lat_38.7_lon_-9.1/
    └── 38.7223_-9.1393_cafe-landmark/
        ├── place.txt
        ├── main-photo.jpg
        └── contributors/
            ├── CR7BBQ/
            │   ├── contributor.txt
            │   ├── interior-photo1.jpg
            │   ├── interior-photo2.jpg
            │   └── detail-shots/
            │       └── tile-detail.jpg
            ├── X135AS/
            │   ├── contributor.txt
            │   ├── aerial-view.jpg
            │   └── drone-video.mp4
            └── BRAVO2/
                └── night-photos/
                    ├── facade-lit.jpg
                    └── street-view.jpg
```

### Contributor Folder Location

**Base Path**: `contributors/CALLSIGN/`

**Characteristics**:
- All contributor folders under `contributors/` subdirectory
- Folder name matches contributor's callsign exactly
- Case-sensitive (CALLSIGN must match)
- One folder per contributor

### Contributor Metadata File

**Filename**: `contributor.txt` (inside contributor folder)

**Format**:
```
# CONTRIBUTOR: CR7BBQ

CREATED: 2025-11-21 14:00_00

My photos from multiple visits to this historic café.

Captured the interior details and the famous azulejo tiles.
Used Sony A7IV with 24-70mm lens.

--> npub: npub1abc123...
--> signature: hex_sig...
```

**Header**:
1. `# CONTRIBUTOR: <callsign>`
2. Blank line
3. `CREATED: YYYY-MM-DD HH:MM_ss`
4. Blank line
5. Description (optional, plain text)
6. Metadata (npub, signature)

**Purpose**:
- Describe contributor's submissions
- Add context (equipment, technique, visits, etc.)
- Optional - contributor folder can exist without it

### Admin Review Process

Contributors submit photos, but admins control final placement:

**Workflow**:
```
1. Contributor uploads photos to contributors/CALLSIGN/
2. Photos remain in contributor folder (visible but marked as "pending")
3. Admin reviews submitted photos
4. Admin has three options:
   a. Approve: Copy photo to main place folder or subfolder
   b. Reject: Delete photo from contributor folder
   c. Keep: Leave in contributor folder as community contribution
5. Original attribution preserved in photo metadata
```

**Admin Actions**:
- **Copy to main**: Photo becomes featured content (attribution preserved)
- **Copy to subfolder**: Organized into appropriate category
- **Keep in contributor folder**: Remains as community content
- **Delete**: Remove low-quality or inappropriate content

### Contributor Permissions

**Contributor Folder Owner**:
- Add/edit/delete files in their own folder
- Edit contributor.txt
- Cannot modify other contributors' folders
- Cannot modify main place content

**Place Admins**:
- Full access to all contributor folders
- Can copy/move photos to main place area
- Can delete inappropriate content
- Attribution to original photographer preserved

**Moderators**:
- Can hide files in contributor folders
- Cannot delete files permanently
- Cannot move files to main area

### Contributor Reactions

Reactions on contributor folders use the pattern:

**Reaction File**: `.reactions/contributors/CALLSIGN.txt`

**Example**:
```
LIKES: X135AS, BRAVO2, ALPHA1

> 2025-11-21 18:00_00 -- X135AS
Excellent photo series! Great eye for detail.
--> npub: npub1xyz...
--> signature: hex_sig

> 2025-11-21 20:00_00 -- BRAVO2
These interior shots are amazing!
```

## Reactions System

### Overview

The reactions system enables granular engagement with places and their content. Users can:
- Like the place itself
- Like individual photos/videos/files
- Like subfolders
- Like contributor folders
- Comment on any of the above

### Reactions Directory

**Location**: `<place-folder>/.reactions/`

**Purpose**: Stores all likes and comments for place and items

**Filename Pattern**: `<target-item>.txt`

**Examples**:
- Place reactions: `.reactions/place.txt`
- Photo reactions: `.reactions/photo1.jpg.txt`
- Subfolder reactions: `.reactions/exterior.txt`
- Contributor reactions: `.reactions/contributors/CR7BBQ.txt`

### Reaction File Format

```
LIKES: CALLSIGN1, CALLSIGN2, CALLSIGN3

> YYYY-MM-DD HH:MM_ss -- COMMENTER
Comment text here.
--> npub: npub1...
--> signature: hex_sig

> YYYY-MM-DD HH:MM_ss -- ANOTHER_USER
Another comment.
```

### Likes Section

**Format**: `LIKES: <callsign1>, <callsign2>, <callsign3>`

**Characteristics**:
- Comma-separated list of callsigns
- Each callsign can appear only once
- Order can be chronological or alphabetical
- Empty if no likes: `LIKES:` (with no callsigns)
- Optional: line can be omitted if no likes

**Example**:
```
LIKES: CR7BBQ, X135AS, BRAVO2, ALPHA1
```

### Comments Section

Comments follow the likes line and use the same format as other collection types:

```
> YYYY-MM-DD HH:MM_ss -- CALLSIGN
Comment content.
--> npub: npub1...
--> signature: hex_sig
```

### Reaction Targets

**Place Reactions** (`.reactions/place.txt`):
- Likes and comments on the place itself
- Most common reaction target

**Photo Reactions** (`.reactions/<filename>.txt`):
- Reactions specific to a photo or video
- Filename must match exactly (case-sensitive)
- Examples:
  - Photo: `.reactions/sunset.jpg.txt`
  - Video: `.reactions/tour.mp4.txt`

**Subfolder Reactions** (`.reactions/<subfolder-name>.txt`):
- Reactions on a subfolder as a whole
- Filename matches subfolder name
- Example: `.reactions/exterior.txt` for `exterior/` subfolder

**Contributor Reactions** (`.reactions/contributors/<callsign>.txt`):
- Reactions on contributor's folder
- Example: `.reactions/contributors/CR7BBQ.txt`

## Comments

Place-level comments now live under `feedback/comments/` using the centralized feedback API. The `.reactions/` comment format below remains for per-photo or per-subfolder legacy reactions.

### Comment Format

```
> YYYY-MM-DD HH:MM_ss -- CALLSIGN
Comment content here.
Can span multiple lines.
--> rating: 5
--> npub: npub1...
--> signature: hex_signature
```

### Comment Structure

1. **Header Line** (required)
   - **Format**: `> YYYY-MM-DD HH:MM_ss -- CALLSIGN`
   - **Example**: `> 2025-11-21 14:30_45 -- X135AS`
   - Starts with `>` followed by space

2. **Content** (required)
   - Plain text, multiple lines allowed
   - No formatting

3. **Metadata** (optional)
   - **rating**: Optional numeric rating (1-5)
     - Format: `--> rating: <1-5>`
     - Example: `--> rating: 5`
     - Use for reviews/recommendations
   - **npub**: NOSTR public key
   - **signature**: NOSTR signature (must be last if present)

### Comment Locations

Comments are stored in reaction files:
- **Place comments**: `.reactions/place.txt`
- **Photo comments**: `.reactions/photo.jpg.txt`
- **Subfolder comments**: `.reactions/subfolder-name.txt`
- **Contributor comments**: `.reactions/contributors/CALLSIGN.txt`

### Comment Characteristics

- **Flat structure**: No nested replies
- **Chronological order**: Sorted by timestamp
- **Multiple targets**: Can comment on different items
- **Persistent**: Comments remain with item

### Reviews and Ratings

Places support user reviews through the comment system with optional ratings:

**Review Format**:
```
> 2025-11-21 14:30_00 -- CR7BBQ
Amazing historic café! The pastries are incredible and the
Art Nouveau interior is stunning. Highly recommended for
coffee and traditional Portuguese sweets.
--> rating: 5
--> npub: npub1abc123...
--> signature: hex_sig...
```

**Rating Scale**:
- **5**: Excellent, highly recommended
- **4**: Very good, recommended
- **3**: Good, average experience
- **2**: Below average, some issues
- **1**: Poor, not recommended

**Calculating Average Rating**:
- Count all comments with rating metadata
- Calculate average of all ratings
- Display as stars (e.g., ⭐⭐⭐⭐⭐ 4.5/5.0)
- Show count (e.g., "Based on 12 reviews")

**Review Best Practices**:
- Ratings are optional; comments without ratings are still valuable
- Be honest and constructive in reviews
- Include specific details (food quality, service, atmosphere, etc.)
- Update review if experience changes over time
- Admins/moderators can hide inappropriate reviews

**Example with Multiple Reviews**:
```
.reactions/place.txt:
LIKES: CR7BBQ, X135AS, BRAVO2, ALPHA1, DELTA4

> 2025-11-21 14:30_00 -- CR7BBQ
Amazing historic café! The pastries are incredible.
--> rating: 5
--> npub: npub1abc123...
--> signature: hex_sig1...

> 2025-11-22 10:15_00 -- X135AS
Good coffee and atmosphere, but service was a bit slow.
--> rating: 4
--> npub: npub1xyz789...
--> signature: hex_sig2...

> 2025-11-23 16:00_00 -- BRAVO2
Beautiful interior! Worth visiting for the architecture alone.
--> rating: 5
--> npub: npub1bravo...
--> signature: hex_sig3...
```
Average rating: 4.67/5.0 (3 reviews)

## Subfolder Organization

### Subfolder Purpose

Subfolders organize related content within a place:
- Group photos by category (e.g., "exterior", "interior", "details")
- Separate different aspects (e.g., "day-photos", "night-photos")
- Organize by season (e.g., "spring", "summer", "autumn", "winter")
- Separate media types (e.g., "videos", "documents", "maps")

### Category-Specific Folder Recommendations

Different place types benefit from different subfolder organization. The system should suggest appropriate folders based on the TYPE field, but all folders remain optional.

**Places with Exterior/Interior Folders** (typically buildings and structures):

*Food & Drink*: restaurant, cafe, bar, fast-food, bakery, ice-cream-shop, tea-house, brewery, winery
- **exterior/**: Building facade, outdoor seating, signage
- **interior/**: Dining area, bar, kitchen views, decor

*Retail & Commerce*: shop, shopping, supermarket, market, grocery-store, convenience-store, department-store, bookstore, pharmacy
- **exterior/**: Storefront, entrance, parking
- **interior/**: Aisles, displays, product selection

*Accommodation*: hotel, hostel, motel, guesthouse, resort
- **exterior/**: Building facade, grounds, pool area
- **interior/**: Rooms, lobby, common areas, amenities

*Cultural & Historic*: monument, museum, art-gallery, castle, palace, temple, church, mosque, synagogue, cathedral, monastery, historic-site
- **exterior/**: Architecture, facade, grounds
- **interior/**: Exhibits, artwork, architectural details

*Urban Infrastructure*: building, skyscraper, tower, bridge, school, office
- **exterior/**: Architecture, surrounding area
- **interior/**: Lobby, significant rooms (if accessible)

*Services*: hospital, clinic, police-station, fire-station, post-office, library, bank
- **exterior/**: Building, parking, accessibility
- **interior/**: Waiting areas, service counters (where appropriate)

*Tourism & Attractions*: theme-park, zoo, aquarium, botanical-garden, observatory, lighthouse, visitor-center
- **exterior/**: Entrance, grounds, outdoor exhibits
- **interior/**: Indoor exhibits, facilities

**Places WITHOUT Exterior/Interior Folders** (natural features, outdoor locations):

*Emergency & Off-Grid*: water-spring, well, shelter, cave, fire-tower, safety-point, bunker
- Use descriptive folders: **approach/**, **source/**, **surroundings/**

*Nature & Wilderness*: mountain-peak, viewpoint, waterfall, lake, river, beach, cliff, canyon, forest, wetland, hot-spring
- Use descriptive folders: **views/**, **trail/**, **seasonal/**, **wildlife/**

*Fruit Trees*: apple-tree, pear-tree, cherry-tree, and all fruit tree types
- Use descriptive folders: **spring-blossoms/**, **summer-fruit/**, **harvest/**, **location/**

*Edible Plants*: berry-bush, blackberry-bush, wild-garlic-patch, mushroom-spot, etc.
- Use descriptive folders: **growing-season/**, **harvest/**, **identification/**, **location/**

*Nut Trees*: walnut-tree, chestnut-tree, hazelnut-bush, etc.
- Use descriptive folders: **spring/**, **autumn-harvest/**, **identification/**, **location/**

*Agriculture & Farming*: farm, orchard, vineyard, crop-field, pasture
- Use descriptive folders: **fields/**, **equipment/**, **harvest/**, **seasonal/**

*Recreation & Sports*: park, playground, sports-field, stadium, golf-course, tennis-court, climbing-area, geocache
- Use activity-based folders: **facilities/**, **trails/**, **equipment/**, **events/**

*Public Spaces*: plaza, town-square, garden, promenade
- Use area-based folders: **central-area/**, **features/**, **events/**, **seasonal/**

*Transportation*: bus-stop, bus-stop-long-distance, train-station, metro-station, airport
- Use functional folders: **platforms/**, **waiting-area/**, **signage/**, **access/**

**UI Implementation Suggestions**:
- When creating a place, suggest relevant folders based on TYPE field
- Pre-create suggested folders for user convenience (empty until photos added)
- Allow users to disable/remove suggested folders
- Always allow custom folder creation regardless of type
- Show folder suggestions as optional, not mandatory

**Example - Restaurant**:
```
38.7223_-9.1393_historic-cafe/
├── place.txt
├── exterior/           # Auto-suggested
│   ├── facade.jpg
│   └── terrace.jpg
├── interior/           # Auto-suggested
│   ├── dining-room.jpg
│   └── bar-area.jpg
└── menu/               # User-created custom folder
    └── menu-2025.pdf
```

**Example - Apple Tree**:
```
38.7145_-9.1501_apple-tree/
├── place.txt
├── spring-blossoms/    # Suggested for fruit trees
│   └── flowers.jpg
├── summer-fruit/       # Suggested for fruit trees
│   └── ripening-apples.jpg
└── location/           # Suggested for outdoor places
    └── access-path.jpg
```

### Subfolder Structure

Each subfolder can contain:
- Media files (photos, videos)
- Documents (PDFs, text files)
- A `subfolder.txt` file describing the subfolder
- Nested subfolders (one level recommended)

### Subfolder Metadata File

**Filename**: `subfolder.txt`

**Format**:
```
# SUBFOLDER: Subfolder Title

CREATED: YYYY-MM-DD HH:MM_ss
AUTHOR: CALLSIGN

Description of this subfolder's contents.

Can include multiple paragraphs explaining
what's organized here.

--> npub: npub1...
--> signature: hex_sig...
```

**Characteristics**:
- Optional (subfolder can exist without metadata file)
- Allows description and attribution
- Can have reactions (likes/comments) via `.reactions/`
- Follows same format as place file but with `# SUBFOLDER:` header

## File Management

### Supported File Types

**Images**:
- JPG, JPEG, PNG, GIF, WebP, BMP, SVG
- Any size (reasonable limits recommended)

**Videos**:
- MP4, AVI, MOV, MKV, WebM
- Recommended: MP4 for compatibility

**Documents**:
- PDF, TXT, MD, DOC, DOCX

**Other**:
- Any file type can be stored in place folder

### File Organization

Files are stored directly in the place folder or subfolders:

```
38.7223_-9.1393_cafe-landmark/
├── place.txt
├── main-photo.jpg
├── menu.pdf
├── interior/
│   ├── subfolder.txt
│   ├── seating-area.jpg
│   ├── bar.jpg
│   └── ceiling-detail.jpg
└── exterior/
    ├── subfolder.txt
    ├── facade.jpg
    └── terrace.jpg
```

### File Naming

**Convention**: Original filenames preserved

**Best Practices**:
- Use descriptive names (e.g., `front-entrance.jpg` not `IMG_1234.jpg`)
- Avoid special characters in filenames
- Use lowercase for consistency
- Include descriptive keywords in filename

**Example Names**:
```
Good:
- historic-facade-morning-light.jpg
- interior-art-nouveau-ceiling.jpg
- azulejo-tile-detail.jpg

Avoid:
- IMG_0001.jpg
- Photo (1).jpg
- DSC_20251121_143045.jpg
```

## Permissions and Roles

### Overview

Places support three distinct roles with different permission levels: Admins, Moderators, and Contributors. This system enables collaborative place documentation while maintaining content quality.

### Roles

#### Place Author

The user who created the place (AUTHOR field).

**Permissions**:
- All admin permissions (author is implicit admin)
- Cannot be removed from admin list
- Can transfer ownership to another admin

#### Admins

Additional administrators listed in ADMINS field.

**Permissions**:
- Edit place.txt (name, description, metadata)
- Add/remove admins and moderators
- Create/delete subfolders
- Add/delete any files
- Delete entire place
- Permanently delete comments and content
- Manage contributor folders:
  - Copy contributor photos to main area
  - Delete inappropriate contributor content
  - Move contributor photos to subfolders
- Override moderation decisions

**Adding Admins**:
```
ADMINS: npub1abc123..., npub1xyz789..., npub1bravo...
```

#### Moderators

Users with moderation privileges listed in MODERATORS field.

**Permissions**:
- Hide comments (move to .hidden/)
- Hide files (move to .hidden/)
- Cannot delete content permanently
- Cannot edit place.txt
- Cannot manage roles
- Can view hidden content
- Can restore hidden content

**Adding Moderators**:
```
MODERATORS: npub1delta..., npub1echo..., npub1foxtrot...
```

#### Contributors

All other users who can access the place.

**Permissions**:
- View place and all content
- Create contributor folder for themselves
- Add files to their contributor folder
- Like place, files, and subfolders
- Comment on place, files, and subfolders
- Delete their own comments
- Edit/delete files in their contributor folder

### Permission Checks

Before any operation, verify user permissions:

```
1. Identify user's role (author, admin, moderator, contributor)
2. Check if action is allowed for that role
3. For destructive actions, require confirmation
4. Log action for audit trail
5. Execute operation
```

## Moderation System

### Overview

The moderation system allows moderators and admins to hide inappropriate content without permanently deleting it. Hidden content is moved to a `.hidden/` directory and can be restored by admins if needed.

### Hidden Content Directory

**Location**: `<place-folder>/.hidden/`

**Purpose**: Store content hidden by moderators

**Structure**:
```
.hidden/
├── comments/
│   ├── place_comment_20251121_143000_SPAMMER.txt
│   └── photo1_comment_20251121_150000_TROLL.txt
├── files/
│   ├── inappropriate-image.jpg
│   └── spam-document.pdf
└── moderation-log.txt
```

### Hiding vs Deleting

**Hiding (Moderators and Admins)**:
- Moves content to `.hidden/`
- Content not visible in UI
- Can be restored by admins
- Logged in moderation-log.txt
- Original metadata preserved

**Deleting (Admins Only)**:
- Permanently removes content
- Cannot be restored
- More severe action
- Used for illegal or harmful content

### Moderation Log

**File**: `.hidden/moderation-log.txt`

**Format**:
```
> 2025-11-21 16:00_00 -- DELTA4 (moderator)
ACTION: hide_comment
TARGET: place.txt
AUTHOR: SPAMMER
REASON: Spam advertising
CONTENT_PREVIEW: Buy my product! Visit...

> 2025-11-21 17:30_00 -- ECHO5 (moderator)
ACTION: hide_file
TARGET: inappropriate-image.jpg
REASON: Inappropriate content

> 2025-11-22 09:00_00 -- CR7BBQ (admin)
ACTION: restore_comment
TARGET: place.txt
AUTHOR: LEGITIMATE_USER
REASON: False positive, comment was fine
```

## NOSTR Integration

### NOSTR Keys

**npub (Public Key)**:
- Bech32-encoded public key
- Format: `npub1` followed by encoded data
- Purpose: Author identification, verification

**nsec (Private Key)**:
- Never stored in files
- Used for signing
- Kept secure in user's keystore

### Signature Format

**Place Signature**:
```
--> npub: npub1qqqqqqqq...
--> signature: 0123456789abcdef...
```

**Comment Signature**:
```
> 2025-11-21 14:30_45 -- CR7BBQ
Great place!
--> npub: npub1abc123...
--> signature: fedcba987654...
```

### Signature Verification

1. Extract npub and signature from metadata
2. Reconstruct signable message content
3. Verify Schnorr signature
4. Display verification badge in UI if valid

## Complete Examples

### Example 1: Simple Place (Single Language)

```
# PLACE: Historic Tower

CREATED: 2025-11-21 10:00_00
AUTHOR: CR7BBQ
COORDINATES: 38.7169,-9.1399
RADIUS: 100
ADDRESS: Praça do Comércio, Lisbon, Portugal
TYPE: monument
FOUNDED: 16th century
HOURS: Daily 9:00-19:00

Historic tower built in the 16th century.

Famous landmark in Lisbon, offering panoramic views
of the city and the Tagus River.

Admission fee required.

HISTORY:
Constructed in 1515 during the reign of King Manuel I, this
tower served as both a fortress and ceremonial gateway to Lisbon.

It survived the devastating earthquake of 1755 and became
a UNESCO World Heritage site in 1983.

--> npub: npub1abc123...
--> signature: 0123456789abcdef...
```

### Example 2: Place with Photos and Reactions

```
Place folder: places/38.7_-9.1/38.7223_-9.1393_historic-cafe/

Files:
- place.txt
- main-entrance.jpg
- interior-view.jpg
- azulejo-tiles.jpg
- .reactions/
  - place.txt
  - main-entrance.jpg.txt
  - interior-view.jpg.txt

=== place.txt ===
# PLACE: Historic Café Landmark

CREATED: 2025-11-21 09:00_00
AUTHOR: X135AS
COORDINATES: 38.7223,-9.1393
RADIUS: 50
ADDRESS: Rua Garrett 120, Chiado, Lisbon
TYPE: restaurant
FOUNDED: 1782
HOURS: Daily 8:00-24:00

Historic café established in 1782.

Famous for its Art Nouveau interior and hand-painted
azulejo tiles. This café has been a meeting place for
Portuguese writers, artists, and intellectuals for
over two centuries.

Specialties include traditional Portuguese pastries
and the famous "bica" espresso.

--> npub: npub1xyz789...
--> signature: abcd1234efgh5678...

=== .reactions/place.txt ===
LIKES: CR7BBQ, BRAVO2, ALPHA1, DELTA4

> 2025-11-21 12:30_00 -- CR7BBQ
Amazing historic place! The interior is stunning. The Art Nouveau
details are exquisite and the traditional pastries are authentic.
--> rating: 5
--> npub: npub1abc123...
--> signature: 111222333...

> 2025-11-21 14:00_00 -- BRAVO2
The pastries here are incredible. Must visit!
--> rating: 5

> 2025-11-22 09:30_00 -- ALPHA1
Good atmosphere but service was a bit slow during busy hours.
Coffee is excellent though.
--> rating: 4
--> npub: npub1alpha...
--> signature: aaa222bbb...

=== .reactions/main-entrance.jpg.txt ===
LIKES: CR7BBQ, X135AS, ALPHA1

> 2025-11-21 13:00_00 -- ALPHA1
Perfect capture of the Art Nouveau facade!
--> npub: npub1alpha...
--> signature: aaa111bbb...
```

### Example 3: Place with Contributors

```
Place folder: places/40.7_-74.0/40.7128_-74.0060_central-park/

Structure:
- place.txt
- main-entrance.jpg
- lake-view.jpg
- contributors/
  - CR7BBQ/
    - contributor.txt
    - spring-blossoms.jpg
    - autumn-colors.jpg
  - X135AS/
    - contributor.txt
    - aerial-view.jpg
    - drone-video.mp4
- .reactions/
  - place.txt
  - contributors/CR7BBQ.txt
  - contributors/X135AS.txt

=== place.txt ===
# PLACE: Central Park

CREATED: 2025-11-21 08:00_00
AUTHOR: CR7BBQ
COORDINATES: 40.7128,-74.0060
RADIUS: 1000
ADDRESS: Central Park, New York, NY 10022
TYPE: park

Iconic urban park in Manhattan, New York City.

Spanning 843 acres, Central Park is one of the most
visited urban parks in the United States. Features
include lakes, theaters, playgrounds, and meadows.

The park is a National Historic Landmark and offers
year-round activities for visitors.

--> npub: npub1abc123...
--> signature: aaa111bbb222...

=== contributors/CR7BBQ/contributor.txt ===
# CONTRIBUTOR: CR7BBQ

CREATED: 2025-11-21 12:00_00

Photos from my seasonal visits to Central Park.

Captured the beauty of spring blossoms and autumn foliage.
Canon EOS R5 with 24-105mm lens.

--> npub: npub1abc123...
--> signature: ccc333ddd444...

=== .reactions/place.txt ===
LIKES: X135AS, BRAVO2, ALPHA1, DELTA4, ECHO5

> 2025-11-21 15:00_00 -- X135AS
Love this place! Best park in NYC.
--> npub: npub1xyz789...
--> signature: eee555fff666...

> 2025-11-21 16:30_00 -- BRAVO2
Great for jogging and picnics!

=== .reactions/contributors/CR7BBQ.txt ===
LIKES: X135AS, BRAVO2

> 2025-11-21 18:00_00 -- X135AS
Beautiful seasonal photography! Love the composition.
--> npub: npub1xyz...
--> signature: ggg777hhh888...
```

### Example 4: Place with Subfolders

```
Place folder: places/51.5_-0.0/51.5055_-0.0754_tower-bridge/

Structure:
- place.txt
- overview.jpg
- exterior/
  - subfolder.txt
  - north-tower.jpg
  - south-tower.jpg
  - suspension-cables.jpg
- interior/
  - subfolder.txt
  - walkway.jpg
  - engine-room.jpg
  - exhibition.jpg
- .reactions/
  - place.txt
  - exterior.txt
  - exterior/north-tower.jpg.txt

=== place.txt ===
# PLACE: Tower Bridge

CREATED: 2025-11-21 10:00_00
AUTHOR: BRAVO2
COORDINATES: 51.5055,-0.0754
RADIUS: 200
ADDRESS: Tower Bridge Rd, London SE1 2UP, UK
TYPE: monument

Iconic combined bascule and suspension bridge in London.

Completed in 1894, Tower Bridge crosses the River Thames
close to the Tower of London. The bridge is one of London's
most famous landmarks.

Features include two towers, a high-level walkway with
glass floors, and the original Victorian engine rooms.

Open to visitors daily. Tickets required for tower access.

--> npub: npub1bravo...
--> signature: 999aaabbb000...

=== exterior/subfolder.txt ===
# SUBFOLDER: Exterior Views

CREATED: 2025-11-21 14:00_00
AUTHOR: BRAVO2

External photographs of Tower Bridge architecture.

Captured from multiple angles showing the iconic
Gothic towers and suspension system.

--> npub: npub1bravo...
--> signature: ccc333ddd444...

=== interior/subfolder.txt ===
# SUBFOLDER: Interior Features

CREATED: 2025-11-21 15:00_00
AUTHOR: BRAVO2

Internal features including the walkway and engine rooms.

Showcases the Victorian engineering and modern
glass floor walkway additions.

--> npub: npub1bravo...
--> signature: eee555fff666...

=== .reactions/place.txt ===
LIKES: CR7BBQ, X135AS, ALPHA1, DELTA4

> 2025-11-21 17:00_00 -- CR7BBQ
Stunning bridge! The engineering is impressive.
--> npub: npub1abc123...
--> signature: ggg777hhh888...

> 2025-11-21 18:30_00 -- X135AS
The glass floor walkway is a must-see experience!

=== .reactions/exterior.txt ===
LIKES: CR7BBQ, ALPHA1

> 2025-11-21 16:00_00 -- ALPHA1
Great collection of exterior shots!
```

### Example 5: Natural Place (Fruit Tree)

```
Place folder: places/38.7_-9.1/38.7145_-9.1501_apple-tree-roadside/

Structure:
- place.txt
- overview.jpg
- spring-blossoms/
  - subfolder.txt
  - white-flowers.jpg
  - bee-pollination.jpg
- summer-fruit/
  - green-apples.jpg
  - ripening-fruit.jpg
- harvest/
  - ripe-apples.jpg
  - harvest-basket.jpg
- location/
  - access-path.jpg
  - landmark-nearby.jpg
- .reactions/
  - place.txt
  - spring-blossoms.txt

=== place.txt ===
# PLACE: Roadside Apple Tree

CREATED: 2025-11-21 08:00_00
AUTHOR: CR7BBQ
COORDINATES: 38.7145,-9.1501
RADIUS: 15
ADDRESS: Near km 23 marker, N247 road, Sintra
TYPE: apple-tree
HOURS: Accessible year-round

Wild apple tree growing beside the N247 road.

Produces medium-sized red apples, typically ready for
harvest in late September to early October. Tree is
healthy and productive, estimated to be 15-20 years old.

Access is easy from the road with a small pull-off area.
Please be respectful and only take what you need.

--> npub: npub1abc123...
--> signature: xyz789def456...

=== spring-blossoms/subfolder.txt ===
# SUBFOLDER: Spring Blossoms

CREATED: 2025-04-15 10:30_00
AUTHOR: CR7BBQ

Photos of the apple blossoms in spring (April).

White flowers with pink edges. Heavy flowering this year
indicates good fruit production for autumn harvest.

--> npub: npub1abc123...
--> signature: aaa111bbb222...

=== summer-fruit/subfolder.txt ===
# SUBFOLDER: Summer Fruit Development

CREATED: 2025-07-20 16:00_00
AUTHOR: X135AS

Fruit development through summer months.

Green apples growing well with good size. No significant
pest damage observed. Fruit should be ready by late September.

--> npub: npub1xyz789...
--> signature: ccc333ddd444...

=== .reactions/place.txt ===
LIKES: X135AS, BRAVO2, ALPHA1

> 2025-09-28 14:00_00 -- X135AS
Great find! The apples were perfect this year. Picked about
2kg for apple pie. Tree looks healthy and well-maintained.
--> rating: 5
--> npub: npub1xyz789...
--> signature: eee555fff666...

> 2025-10-05 11:30_00 -- BRAVO2
Stopped by today but most apples are gone. Good to know
for next year though. Thanks for documenting this!
--> npub: npub1bravo...
--> signature: ggg777hhh888...

> 2025-10-12 09:00_00 -- ALPHA1
This is exactly the kind of foraging info we need. Please
add more fruit trees to the collection!
--> rating: 5

=== .reactions/spring-blossoms.txt ===
LIKES: CR7BBQ, X135AS

> 2025-04-20 12:00_00 -- X135AS
Beautiful blossoms! Can't wait for harvest season.
--> npub: npub1xyz...
--> signature: iii999jjj000...
```

### Example 6: Multilanguage Place (Monument)

```
Place folder: places/38.7_-9.1/38.7169_-9.1399_monastery/

=== place.txt ===
# PLACE_EN: Jerónimos Monastery
# PLACE_PT: Mosteiro dos Jerónimos
# PLACE_ES: Monasterio de los Jerónimos
# PLACE_FR: Monastère des Hiéronymites

CREATED: 2025-11-21 15:00_00
AUTHOR: CR7BBQ
COORDINATES: 38.6979,-9.2063
RADIUS: 200
ADDRESS: Praça do Império, 1400-206 Lisbon, Portugal
TYPE: monastery
FOUNDED: 1501
HOURS: Tue-Sun 10:00-17:30

[EN]
The Jerónimos Monastery is a former monastery of the Order of Saint Jerome
near the Tagus river in the parish of Belém, Lisbon, Portugal.

This masterpiece of Portuguese Late Gothic Manueline architecture stands
as a monument to Portugal's Age of Discovery and is one of the most
prominent examples of the Portuguese Late Gothic style.

The monastery was classified as a UNESCO World Heritage Site in 1983.

[PT]
O Mosteiro dos Jerónimos é um antigo mosteiro da Ordem de São Jerónimo
localizado na freguesia de Belém, em Lisboa, Portugal.

Esta obra-prima da arquitetura manuelina portuguesa tardia representa
a Era dos Descobrimentos de Portugal e é um dos exemplos mais proeminentes
do estilo gótico tardio português.

O mosteiro foi classificado como Património Mundial da UNESCO em 1983.

[ES]
El Monasterio de los Jerónimos es un antiguo monasterio de la Orden de
San Jerónimo cerca del río Tajo en la parroquia de Belém, Lisboa, Portugal.

Esta obra maestra de la arquitectura manuelina portuguesa tardía se
erige como un monumento a la Era de los Descubrimientos de Portugal
y es uno de los ejemplos más destacados del estilo gótico tardío portugués.

El monasterio fue declarado Patrimonio de la Humanidad por la UNESCO en 1983.

[FR]
Le Monastère des Hiéronymites est un ancien monastère de l'Ordre de
Saint-Jérôme près du fleuve Tage dans la paroisse de Belém, Lisbonne, Portugal.

Ce chef-d'œuvre de l'architecture manuéline portugaise tardive est un
monument de l'Âge des Découvertes du Portugal et est l'un des exemples
les plus remarquables du style gothique tardif portugais.

Le monastère a été classé au patrimoine mondial de l'UNESCO en 1983.

HISTORY_EN:
King Manuel I commissioned the monastery in 1501 to commemorate Vasco da Gama's
successful voyage to India. Construction began in 1501 and was completed around
1601, spanning 100 years.

The monastery was originally inhabited by monks of the Order of Saint Jerome,
whose role was to provide spiritual guidance to mariners and pray for the
king's soul.

The building was largely spared by the 1755 earthquake, although the bell
tower collapsed. It was later declared a national monument in 1907.

HISTORY_PT:
O Rei Manuel I encomendou o mosteiro em 1501 para comemorar a viagem bem-sucedida
de Vasco da Gama à Índia. A construção começou em 1501 e foi concluída por volta
de 1601, abrangendo 100 anos.

O mosteiro foi originalmente habitado por monges da Ordem de São Jerónimo,
cujo papel era fornecer orientação espiritual aos marinheiros e rezar pela
alma do rei.

O edifício foi em grande parte poupado pelo terramoto de 1755, embora a torre
do sino tenha desabado. Foi posteriormente declarado monumento nacional em 1907.

HISTORY_ES:
El Rey Manuel I encargó el monasterio en 1501 para conmemorar el exitoso viaje
de Vasco da Gama a la India. La construcción comenzó en 1501 y se completó
alrededor de 1601, abarcando 100 años.

El monasterio fue originalmente habitado por monjes de la Orden de San Jerónimo,
cuyo papel era proporcionar orientación espiritual a los marineros y rezar por
el alma del rey.

El edificio se salvó en gran medida del terremoto de 1755, aunque la torre del
campanario se derrumbó. Posteriormente fue declarado monumento nacional en 1907.

HISTORY_FR:
Le Roi Manuel Ier a commandé le monastère en 1501 pour commémorer le voyage
réussi de Vasco de Gama en Inde. La construction a commencé en 1501 et s'est
achevée vers 1601, s'étalant sur 100 ans.

Le monastère était à l'origine habité par des moines de l'Ordre de Saint-Jérôme,
dont le rôle était de fournir des conseils spirituels aux marins et de prier
pour l'âme du roi.

Le bâtiment a été largement épargné par le tremblement de terre de 1755, bien
que le clocher se soit effondré. Il a ensuite été déclaré monument national en 1907.

--> npub: npub1abc123...
--> signature: xyz789abc456def...
```

## Parsing Implementation

### Place File Parsing

```
1. Read place.txt as UTF-8 text
2. Parse title lines:
   - Single language: "# PLACE: <name>"
   - Multilanguage: "# PLACE_XX: <name>" (XX = language code in uppercase)
   - Extract all language variants into Map<String, String>
   - Continue reading consecutive title lines until non-title line
3. Verify at least one title exists
4. Parse header lines:
   - CREATED: timestamp
   - AUTHOR: callsign
   - COORDINATES: lat,lon
   - RADIUS: meters (10-1000)
   - ADDRESS: (optional)
   - TYPE: (optional)
   - FOUNDED: (optional)
   - HOURS: (optional)
   - ADMINS: (optional)
   - MODERATORS: (optional)
5. Find content start (after header blank line)
6. Parse content section:
   - Single language: Read until HISTORY or metadata
   - Multilanguage: Look for [XX] markers
     - Extract content for each language into Map<String, String>
     - Continue until HISTORY section or metadata
7. Parse HISTORY section (optional):
   - Single language: "HISTORY:" followed by content
   - Multilanguage: "HISTORY_XX:" for each language
   - Extract history for each language into Map<String, String>
8. Extract metadata (npub, signature)
9. Validate signature placement (must be last)
```

### Region Calculation

```
1. Extract coordinates from COORDINATES field
2. Round latitude to 1 decimal place
3. Round longitude to 1 decimal place
4. Format region folder: {LAT}_{LON}/
5. Check for numbered subfolders (001/, 002/, etc.)
6. Verify place folder is in correct region/subfolder
```

### Reaction File Parsing

```
1. Read .reactions/<item>.txt
2. Parse LIKES line (comma-separated callsigns)
3. Parse comments:
   - Extract timestamp and author from header
   - Read content lines
   - Parse metadata (rating, npub, signature)
   - Extract rating value (1-5) if present
4. Associate with target item
5. Calculate average rating from all comments with ratings
```

### File Enumeration

```
1. List all files in place folder (exclude . files)
2. Identify subfolders
3. For each subfolder:
   - Check for subfolder.txt
   - List files in subfolder
   - Recursively enumerate nested subfolders
4. Build file tree structure
5. Cross-reference with .reactions/ for engagement data
```

## File Operations

### Creating a Place

```
1. Sanitize place name
2. Generate folder name: {lat}_{lon}_name/
3. Calculate region from coordinates (round to 1 decimal)
4. Create region directory if needed: {LAT}_{LON}/
5. Determine place location within region:
   a. Count existing places in region
   b. If count < 10,000: Place goes directly in region folder
   c. If count ≥ 10,000:
      - Calculate subfolder number: (count / 10,000) + 1
      - Format subfolder: 001/, 002/, etc.
      - Create subfolder if needed
   d. If migrating from flat to subfolder structure:
      - Create 001/ subfolder
      - Move all existing places to 001/
      - Create new place in appropriate subfolder
6. Create place folder: {LAT}_{LON}/{lat}_{lon}_name/
   or: {LAT}_{LON}/00X/{lat}_{lon}_name/
7. Create place.txt with header and content
8. Create .reactions/ directory
9. Set folder permissions (755)
```

**Example Migration**:
```
Initial structure (9,999 places):
38.7_-9.1/
├── place1/
├── place2/
└── place9999/

After 10,000th place added:
38.7_-9.1/
├── 001/                    # All previous places moved here
│   ├── place1/
│   ├── place2/
│   └── place9999/
└── 002/                    # New place
    └── place10000/
```

### Adding Files to Place

```
1. Verify place exists
2. Copy file(s) to place folder or subfolder
3. Preserve original filenames
4. Set file permissions (644)
5. Update UI/index with new files
```

### Creating Contributor Folder

```
1. Verify place exists
2. Create contributors/ folder if needed
3. Create contributors/CALLSIGN/ folder
4. Optionally create contributor.txt
5. Set folder permissions (755)
6. Update place index
```

### Admin Copying Contributor Photo

```
1. Verify user is admin
2. Select photo from contributors/CALLSIGN/
3. Copy to main place folder or subfolder
4. Preserve original filename
5. Add attribution metadata (optional)
6. Original remains in contributor folder
7. Update place index
```

### Adding a Like

```
1. Determine target (place, file, subfolder, or contributor)
2. Generate reaction filename: .reactions/<target>.txt
3. Read existing reaction file or create new
4. Parse LIKES line
5. Check if user already liked
6. If not, add callsign to LIKES list
7. Write updated reaction file
```

### Adding a Comment

```
1. Determine target item
2. Generate reaction filename
3. Read existing or create new
4. Append comment:
   - Header line with timestamp and author
   - Content lines
   - Metadata (npub, signature)
5. Write updated reaction file
```

### Deleting a Place

```
1. Verify user has permission (creator or admin)
2. Recursively delete place folder and all contents:
   - All files
   - All subfolders
   - contributors/ directory
   - .reactions/ directory
3. Update place index
4. Check if numbered subfolder is empty:
   - If empty, optionally delete subfolder
5. Check if region folder is empty:
   - If empty, optionally delete region
```

### Searching Places in Dense Regions

```
1. Calculate region from search coordinates
2. Check if region has numbered subfolders:
   a. If no subfolders: Search directly in region folder
   b. If subfolders exist: Search across all subfolders (001/, 002/, etc.)
3. For proximity searches:
   - Search primary region and neighboring regions
   - Consider radius overlap between regions
4. Build result list from all matching places
5. Sort by distance from search point
```

**Optimization**:
- Index place locations for faster searches
- Cache region/subfolder structure
- Pre-filter by bounding box before distance calculation

## Validation Rules

### Place Validation

- [x] First line must start with `# PLACE: ` or `# PLACE_XX: ` (multilanguage)
- [x] At least one title required (any language)
- [x] Language codes must be two letters, uppercase (EN, PT, ES, FR, DE, IT, NL, RU, ZH, JA, AR)
- [x] Name must not be empty for each language
- [x] CREATED line must have valid timestamp
- [x] AUTHOR line must have non-empty callsign
- [x] COORDINATES must be valid lat,lon
- [x] RADIUS must be integer 1-1000
- [x] TYPE field is required (categorization)
- [x] Description is required (content section must have text)
- [x] Header must end with blank line
- [x] Signature must be last metadata if present
- [x] Folder name must match {lat}_{lon}_* pattern
- [x] Place folder must be in correct region folder
- [x] If in numbered subfolder, subfolder must match 001-999 pattern
- [x] Region folder must match {LAT}_{LON} pattern (1 decimal place)

### Multilanguage Validation

- [x] Language block markers must use format `[XX]` where XX is two-letter code
- [x] HISTORY fields must use format `HISTORY:` or `HISTORY_XX:`
- [x] All language codes must be consistent (uppercase in headers, uppercase in brackets)
- [x] At least one content language required if multilanguage format used
- [x] Fallback to English (EN) recommended but not required
- [x] History sections are optional for all languages

### Coordinate Validation

**Full Precision (Place)**:
- Latitude: -90.0 to +90.0
- Longitude: -180.0 to +180.0
- Format: `lat,lon` (no spaces)
- Precision: Up to 6 decimal places

**Rounded (Region)**:
- Latitude: 1 decimal place
- Longitude: 1 decimal place
- Range: -90.0 to +90.0, -180.0 to +180.0

### Radius Validation

- Must be integer
- Minimum: 1 meter
- Maximum: 1000 meters
- Default: 5 meters
- Format: `RADIUS: <number>` (no units in value)

### Founded Validation

- Optional field
- Freeform text (no strict format enforced)
- Accepted formats:
  - Specific year: `1782`, `2001`
  - Century: `12th century`, `16th century`
  - Approximate: `circa 1500`, `around 1600`
  - Era: `Roman era`, `Medieval period`
  - Range: `1500-1550`
- Should be human-readable
- Maximum length: 50 characters recommended
- Especially useful for TYPE: monument, castle, church, historic-site

### Hours Validation

- Optional field
- Freeform text (no strict format enforced)
- Recommended formats:
  - `Daily HH:MM-HH:MM`
  - `Mon-Fri HH:MM-HH:MM, Sat-Sun HH:MM-HH:MM`
  - `24/7`
  - `Seasonal (Month-Month)`
- Should be human-readable
- Maximum length: 100 characters recommended

### Rating Validation

- Optional metadata in comments
- Format: `--> rating: <1-5>`
- Must be integer from 1 to 5
- Only one rating per comment
- Rating must appear before npub/signature if present
- Cannot modify rating after comment is posted (delete and repost instead)

### Reaction File Validation

- Filename must match existing file/folder/place
- LIKES line format: `LIKES: callsign1, callsign2`
- No duplicate callsigns in LIKES list
- Comments must have valid timestamp
- Signature must be last if present

## Best Practices

### For Place Creators

1. **Accurate coordinates**: Use precise GPS coordinates
2. **Appropriate radius**: Match radius to actual place size
3. **Clear descriptions**: Write detailed, informative descriptions
4. **Quality photos**: Upload clear, well-composed images
5. **Organize content**: Use subfolders for large collections
6. **Complete address**: Include full address for easier finding
7. **Categorize**: Use TYPE field for filtering
8. **Sign places**: Use npub/signature for authenticity

### For Contributors

1. **Respect guidelines**: Follow place rules and theme
2. **Quality submissions**: Share your best photos
3. **Add context**: Use contributor.txt to describe your work
4. **Proper attribution**: Sign your contributions
5. **Organize**: Use subfolders in your contributor folder
6. **Engage**: Like and comment on others' work

### For Developers

1. **Validate input**: Check all coordinates and radius values
2. **Region calculation**: Ensure correct region placement
3. **Atomic operations**: Use temp files for updates
4. **Permission checks**: Verify user rights before operations
5. **Handle errors**: Gracefully handle missing/invalid files
6. **Optimize reads**: Cache place metadata, lazy-load files
7. **Index reactions**: Build indexes for performance
8. **Map integration**: Integrate with mapping services

### For Administrators

1. **Review contributions**: Regularly check contributor folders
2. **Curate content**: Promote best photos to main area
3. **Moderate fairly**: Apply consistent standards
4. **Size limits**: Set reasonable file size limits
5. **Monitor storage**: Track disk usage per region
6. **Monitor density**: Watch for regions approaching 10,000 places
7. **Migration planning**: Plan for subfolder migration in dense regions
8. **Backup strategy**: Regular backups of places/
9. **Archive old**: Consider archiving unused places
10. **Index maintenance**: Keep search indexes updated for dense regions

## Security Considerations

### Access Control

**Place Creator**:
- Edit place.txt
- Delete place and all contents
- Create/delete subfolders
- Moderate all comments
- Manage contributor content

**Admins**:
- Same as place creator
- Can be added/removed by creator

**Moderators**:
- Hide comments and files
- Cannot delete permanently
- Cannot edit place.txt

**Contributors**:
- Create own contributor folder
- Add/edit/delete own contributions
- Like and comment on content
- Cannot modify place or others' content

### File Security

**Permissions**:
- Place folders: 755 (rwxr-xr-x)
- Files: 644 (rw-r--r--)
- No execute permissions on uploaded files

**Path Validation**:
- Prevent directory traversal (../)
- Validate filenames (no special chars)
- Check file types before storage
- Scan for malicious content (if applicable)

### Location Privacy

**Coordinate Precision**:
- 6 decimal places ≈ 0.1 meter precision
- Consider privacy before using exact coordinates
- For private residences, use approximate coordinates
- Offset sensitive locations slightly

**Radius Considerations**:
- Small radius reveals specific location
- Large radius provides more privacy
- Balance accuracy with privacy needs

### Threat Mitigation

**File Upload Abuse**:
- Set maximum file sizes
- Limit total place size
- Validate file types
- Scan for malware

**Spam Prevention**:
- Rate limit likes and comments
- Require NOSTR signatures for actions
- Moderate content via .hidden/ system

**Data Integrity**:
- Use NOSTR signatures
- Hash files for integrity checks
- Regular backups
- Validate on read

## Related Documentation

- [Events Format Specification](events-format-specification.md)
- [Blog Format Specification](blog-format-specification.md)
- [Chat Format Specification](chat-format-specification.md)
- [Forum Format Specification](forum-format-specification.md)
- [Centralized Feedback API](../API_feedback.md)
- [Collection File Formats](../others/file-formats.md)
- [NOSTR Protocol](https://github.com/nostr-protocol/nostr)

## Change Log

### Version 1.4 (2025-12-24)

- Added place-level feedback folder (`feedback/`) for centralized likes/comments

### Version 1.3 (2025-12-23)

**Breaking Changes**:
- **TYPE is now required**: Place type field is mandatory for all new places
- **Description is now required**: Content section must contain a description

**Improvements**:
- **Minimum Radius Reduced**: Reduced from 10m to 1m for precise locations (fruit trees, markers)
- **Default Radius**: Changed default radius to 5m for better precision
- **Standard Images Folder**: Photos should be stored in `images/` subfolder (sequential naming: photo1.jpg, photo2.jpg)
- **Photo Management**: Added UI support for adding, viewing, and removing photos

**Documentation Updates**:
- Updated radius constraints and validation
- Added images/ folder as standard photo location
- Updated validation rules for required fields

### Version 1.2 (2025-11-22)

**Major Features**:
- **Multilanguage Support**: Full multilanguage support for places
  - Multilanguage titles: `# PLACE_EN:`, `# PLACE_PT:`, `# PLACE_ES:`, etc.
  - Multilanguage descriptions: `[EN]`, `[PT]`, `[ES]` content blocks
  - Multilanguage history: `HISTORY_EN:`, `HISTORY_PT:`, `HISTORY_ES:`
  - 11 supported languages: EN, PT, ES, FR, DE, IT, NL, RU, ZH, JA, AR
  - Fallback chain: Requested language → English → First available
- **Foundation Date**: Added optional FOUNDED field
  - Supports specific years (e.g., `1782`)
  - Supports centuries (e.g., `16th century`)
  - Supports approximate dates (e.g., `circa 1500`)
  - Flexible format for historic monuments and buildings
- **History Section**: Added optional HISTORY section
  - Separate from main description
  - Supports multilanguage (HISTORY_XX:)
  - Ideal for detailed historical context
  - Useful for monuments, archaeological sites, heritage locations

**Documentation Updates**:
- Added Example 6: Comprehensive multilanguage monument (Jerónimos Monastery)
- Updated Examples 1 and 2 with FOUNDED field
- Enhanced parsing implementation for multilanguage
- Added multilanguage validation rules
- Added FOUNDED validation guidelines

### Version 1.1 (2025-11-21)

**Enhanced Features**:
- **Opening Hours**: Added optional HOURS field in place header
  - Flexible format for operating hours
  - Examples: Daily hours, weekday/weekend split, 24/7, seasonal
- **Reviews and Ratings**: Added optional rating metadata to comments
  - 1-5 star rating scale
  - Integrated with existing comment system
  - Average rating calculation from all rated comments
- **Place Types Reference**: Comprehensive list of 204 recommended place types
  - Organized into 22 categories
  - Survival/off-grid focus (water sources, edible plants, fruit trees)
  - Urban and tourism types (restaurants, monuments, parks)
- **Category-Specific Folder Recommendations**:
  - Guidance on when to use exterior/interior folders
  - Alternative folder suggestions for natural places
  - UI implementation suggestions for auto-suggesting folders
  - Examples for both building-based and natural places

### Version 1.0 (2025-11-21)

**Initial Specification**:
- Coordinate-based organization with ~30,000 regions
- Two-level folder structure (region/place)
  - Compact region naming: `{LAT}_{LON}/` (e.g., `38.7_-9.1/`)
  - Simplified format (removed "lat_" and "lon_" prefixes)
- Dense region support with numbered subfolders:
  - Automatic subfolder creation (001/, 002/, etc.) at 10,000 place threshold
  - Maintains filesystem performance in dense urban areas
  - Seamless migration from flat to subfolder structure
  - Virtually unlimited capacity per region (999 subfolders × 10,000 places)
- Place metadata with coordinates and radius (10m-1000m)
- Photo organization with individual reactions
- Contributor system with admin review
- Subfolder organization
- Granular reactions system (likes on places, files, subfolders, contributors)
- Granular comments system (comments on places, files, subfolders, contributors)
- Admin/moderator permission system
- Moderation system with .hidden/ directory
- Simple text format (no markdown)
- NOSTR signature integration
- Address and type categorization
