# Service Format Specification

**Version**: 1.1
**Last Updated**: 2025-12-28
**Status**: Draft

## Table of Contents

- [Overview](#overview)
- [File Organization](#file-organization)
- [Geographic Organization](#geographic-organization)
- [Service Format](#service-format)
- [Service Offerings](#service-offerings)
- [Pricing Information](#pricing-information)
- [Service Types Reference](#service-types-reference)
- [Contact Information](#contact-information)
- [Service Radius](#service-radius)
- [Photos and Media](#photos-and-media)
- [Feedback System](#feedback-system)
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

This document specifies the text-based format used for storing service provider information in the Geogram system. The services collection type provides a platform for professionals and businesses to list their services, share contact details, and receive community feedback.

### Key Features

- **Multiple Services per Provider**: Each provider can list several expertises with individual descriptions
- **Geographic Organization**: Services organized by country and city (matched from internal database)
- **Service Radius**: Define geographic coverage area (1-200 km, default 30 km)
- **Pricing Information**: Cost per hour/day/service with currency
- **Multilingual Content**: Names and descriptions switch based on client language
- **Contact Information**: Phone, email, website, and direct messaging
- **Operating Hours**: Optional schedule field
- **Profile Picture**: Select one photo as the provider's profile image
- **Feedback Integration**: Uses centralized feedback API (likes, ratings, comments)
- **NOSTR Integration**: Cryptographic signatures for authenticity
- **~68 Predefined Service Types**: Categorized professions for easy filtering

### Use Cases

- Local mechanics advertising their services
- Freelance professionals (tutors, photographers, designers)
- Home service providers (plumbers, electricians, cleaners)
- Personal care services (hairdressers, massage therapists)
- Professional services (lawyers, accountants, notaries)
- Creative professionals (artists, musicians, writers)
- Tech professionals (programmers, software developers, IT consultants)

## File Organization

### Directory Structure

Services are organized by **country** and **city**, with the city determined by matching coordinates to the nearest city/village in the internal city database.

```
devices/{callsign}/services/
├── portugal/                               # Country folder (lowercase)
│   └── coimbra/                            # City folder (lowercase)
│       └── X1ABCD_mechanics-silva/         # Service folder
│           ├── service.txt                 # Main service file
│           ├── media/                      # Media storage
│           │   ├── media1.jpg
│           │   └── media2.jpg
│           └── feedback/                   # Centralized feedback
│               ├── likes.txt
│               ├── ratings.txt             # Ratings with comments
│               ├── subscribe.txt
│               └── comments/
│                   └── 2025-12-28_10-30-00_Y2EFGH.txt
├── united-states/                          # Another country
│   └── new-york/                           # City
│       └── Y2EFGH_maria-tutoring/
│           ├── service.txt
│           └── media/
└── united-kingdom/
    └── london/
        └── Z3IJKL_techfix-pro/
            ├── service.txt
            └── media/
```

### Country Folder Naming

**Pattern**: `{country-name}/`

**Rules**:
- Lowercase
- Replace spaces with hyphens
- Use English name of country
- Derived from coordinates via city database lookup

**Examples**:
```
portugal/           # Portugal
united-states/      # United States
united-kingdom/     # United Kingdom
germany/            # Germany
brazil/             # Brazil
```

### City Folder Naming

**Pattern**: `{city-name}/`

**Rules**:
- Lowercase
- Replace spaces with hyphens
- City/village name from internal database
- Matched to nearest city based on coordinates

**Examples**:
```
lisbon/             # Lisboa, Portugal
coimbra/            # Coimbra, Portugal
new-york/           # New York, USA
london/             # London, UK
sao-paulo/          # São Paulo, Brazil
```

### Service Folder Naming

**Pattern**: `{CALLSIGN}_{sanitized-name}/`

**Components**:
- **CALLSIGN**: Author's callsign (e.g., X1ABCD)
- **sanitized-name**: Cleaned service name

**Sanitization Rules**:
1. Convert name to lowercase
2. Replace spaces and underscores with single hyphens
3. Remove all non-alphanumeric characters (except hyphens)
4. Collapse multiple consecutive hyphens
5. Remove leading/trailing hyphens
6. Truncate to 50 characters

**Examples**:
```
Name: "Mechanics Silva"
Author: X1ABCD
→ X1ABCD_mechanics-silva/

Name: "Maria's Tutoring & Teaching"
Author: Y2EFGH
→ Y2EFGH_marias-tutoring-teaching/

Name: "TechFix Pro - Repairs"
Author: Z3IJKL
→ Z3IJKL_techfix-pro-repairs/
```

## Geographic Organization

### City Database Lookup

When creating a service, the system:

1. Takes the coordinates from the COORDINATES field (mandatory)
2. Queries the internal city database for the nearest city/village
3. Retrieves the city name and country
4. Creates the folder structure: `{country}/{city}/{callsign}_{name}/`

### Internal City Database

The system maintains a database of cities and villages with:
- City/village name (localized and English)
- Country
- Coordinates (latitude, longitude)
- Population (for ranking)

### Location Resolution

```
Given coordinates: 40.2033, -8.4103

1. Query city database for nearest city
2. Result: Coimbra, Portugal
3. Create folder path: portugal/coimbra/
4. Service created in: portugal/coimbra/X1ABCD_service-name/
```

### Fallback Behavior

If no city is found within reasonable distance:
- Use the nearest known location
- Or create a region folder based on coordinates: `{LAT}_{LON}/`

### Benefits of City-Based Organization

1. **Human Readable**: Easy to browse by location
2. **Intuitive**: Users can find services by city name
3. **Scalable**: Works well with any number of services
4. **SEO Friendly**: Meaningful URLs for web interfaces

## Service Format

### Main Service File

Every service must have a `service.txt` file in the service folder root.

**Complete Structure (Single Language)**:
```
# SERVICE: Provider Name

CREATED: YYYY-MM-DD HH:MM_ss
AUTHOR: CALLSIGN
COORDINATES: lat,lon
RADIUS: kilometers
ADDRESS: Full Address (optional)
HOURS: Operating hours (optional)
PROFILE_PIC: media/media1.jpg (optional)
ADMINS: npub1abc123... (optional)

PHONE: +351-912-345-678 (optional)
EMAIL: contact@example.com (optional)
WEBSITE: https://example.com (optional)

PRICE: 25 (optional)
CURRENCY: EUR (optional)
PRICE_UNIT: hour (optional - hour/day/service)

## ABOUT
About the provider - general introduction, experience, certifications.
Multiple lines supported.

## OFFERING: service-type
Description of this specific service/expertise.
What you do, your experience, pricing info, etc.

## OFFERING: another-type
Description of another service offered.

--> npub: npub1...
--> signature: hex_signature
```

**Complete Structure (Multilanguage)**:
```
# SERVICE_EN: Provider Name in English
# SERVICE_PT: Nome do Prestador em Português

CREATED: YYYY-MM-DD HH:MM_ss
AUTHOR: CALLSIGN
COORDINATES: lat,lon
RADIUS: kilometers
ADDRESS: Full Address (optional)
HOURS: Mon-Fri 9:00-18:00, Sat 10:00-14:00 (optional)
PROFILE_PIC: media/media1.jpg (optional)
ADMINS: npub1abc123... (optional)

PHONE: +351-912-345-678
EMAIL: contact@example.com
WEBSITE: https://example.com

PRICE: 50
CURRENCY: EUR
PRICE_UNIT: hour

## ABOUT
[EN]
About the provider in English - general introduction, experience, certifications.
Multiple lines supported.

[PT]
Sobre o prestador em Português - introdução geral, experiência, certificações.

## OFFERING: plumber
[EN]
Plumbing services including pipe repair, leak detection, bathroom installations.
15 years of experience with residential and commercial plumbing.

[PT]
Serviços de canalização incluindo reparação de tubos, deteção de fugas.
15 anos de experiência em canalização residencial e comercial.

## OFFERING: electrician
[EN]
Electrical work for homes and small businesses. Licensed electrician.

[PT]
Trabalhos elétricos para casas e pequenos negócios. Eletricista certificado.

--> npub: npub1...
--> signature: hex_signature
```

### Header Section

1. **Title Line** (required)
   - **Single Language Format**: `# SERVICE: <name>`
   - **Multilanguage Format**: `# SERVICE_XX: <name>`
     - XX = two-letter language code in uppercase (EN, PT, ES, FR, DE, IT, NL, RU, ZH, JA, AR)
   - **Examples**:
     - Single: `# SERVICE: John's Repair Services`
     - Multi: `# SERVICE_EN: John's Repair Services`
     - Multi: `# SERVICE_PT: Serviços de Reparação do João`
   - **Note**: At least one language title required

2. **Blank Line** (required)
   - Separates title from metadata

3. **Created Timestamp** (required)
   - **Format**: `CREATED: YYYY-MM-DD HH:MM_ss`
   - **Example**: `CREATED: 2025-12-28 10:30_00`
   - **Note**: Underscore before seconds

4. **Author Line** (required)
   - **Format**: `AUTHOR: <callsign>`
   - **Example**: `AUTHOR: X1ABCD`
   - **Note**: Author is automatically an admin

5. **Coordinates** (required)
   - **Format**: `COORDINATES: <lat>,<lon>`
   - **Example**: `COORDINATES: 38.7223,-9.1393`
   - **Purpose**: Base location or office address
   - **Precision**: Up to 6 decimal places recommended

6. **Radius** (required)
   - **Format**: `RADIUS: <kilometers>`
   - **Example**: `RADIUS: 30`
   - **Constraints**: 1 to 200 kilometers
   - **Default**: 30 km
   - **Purpose**: Defines the service coverage area

7. **Address** (optional)
   - **Format**: `ADDRESS: <full address>`
   - **Example**: `ADDRESS: Rua da Paz 123, Lisboa, Portugal`
   - **Purpose**: Human-readable location description

8. **Hours** (optional)
   - **Format**: `HOURS: <operating hours>`
   - **Examples**:
     - `HOURS: Mon-Fri 9:00-18:00, Sat 10:00-14:00`
     - `HOURS: Daily 8:00-20:00`
     - `HOURS: 24/7 Emergency Service`
     - `HOURS: By appointment only`
   - **Purpose**: Indicate availability

9. **Profile Picture** (optional)
   - **Format**: `PROFILE_PIC: <relative-path>`
   - **Example**: `PROFILE_PIC: media/media1.jpg`
   - **Purpose**: Main profile image for the service provider

10. **Admins** (optional)
    - **Format**: `ADMINS: <npub1>, <npub2>, ...`
    - **Example**: `ADMINS: npub1abc123..., npub1xyz789...`
    - **Note**: Author is always admin

### Contact Section

Contact fields appear after the header metadata:

11. **Phone** (optional)
    - **Format**: `PHONE: <phone number>`
    - **Example**: `PHONE: +351-912-345-678`

12. **Email** (optional)
    - **Format**: `EMAIL: <email address>`
    - **Example**: `EMAIL: contact@example.com`

13. **Website** (optional)
    - **Format**: `WEBSITE: <url>`
    - **Example**: `WEBSITE: https://johnrepairs.pt`

### Direct Messaging

Users can send 1:1 messages directly to the service provider through the Geogram messaging system. This is built-in and doesn't require additional configuration.

**How it works**:
- The service author's callsign (AUTHOR field) is used for direct messaging
- UI shows a "Send Message" button that opens the chat interface
- Messages are sent via Geogram's encrypted chat system
- No external apps (WhatsApp, Instagram, etc.) required

**UI Display**:
- **Send Message** button: Opens direct chat with provider
- **Call** button: Dials phone number (if PHONE provided)
- **Email** button: Opens email client (if EMAIL provided)
- **Website** link: Opens external browser (if WEBSITE provided)

### Pricing Section

Pricing fields appear after contact information:

14. **Price** (optional)
    - **Format**: `PRICE: <number>`
    - **Example**: `PRICE: 50`
    - **Purpose**: Base price for services

15. **Currency** (optional, required if PRICE set)
    - **Format**: `CURRENCY: <ISO 4217 code>`
    - **Examples**: `EUR`, `USD`, `GBP`, `BRL`
    - **Purpose**: Currency for the price

16. **Price Unit** (optional, required if PRICE set)
    - **Format**: `PRICE_UNIT: <hour|day|service>`
    - **Values**:
      - `hour`: Price per hour of work
      - `day`: Price per day of work
      - `service`: Price per service/job (fixed rate)
    - **Example**: `PRICE_UNIT: hour`

**Pricing Examples**:
```
# €50 per hour (common for professionals)
PRICE: 50
CURRENCY: EUR
PRICE_UNIT: hour

# $500 per day (for full-day jobs)
PRICE: 500
CURRENCY: USD
PRICE_UNIT: day

# €200 fixed price per service
PRICE: 200
CURRENCY: EUR
PRICE_UNIT: service
```

**Note**: Pricing is a general indication. Actual prices may vary based on job complexity. Detailed pricing can be described in the ABOUT or OFFERING sections.

### About Section

The ABOUT section contains the provider's general introduction.

**Single Language Format**:
```
## ABOUT
About text here.
Multiple paragraphs allowed.

Each paragraph separated by blank line.
```

**Multilanguage Format**:
```
## ABOUT
[EN]
About text in English.
Multiple paragraphs allowed.

[PT]
Texto sobre em Português.
Vários parágrafos permitidos.
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

## Service Offerings

### Overview

A service provider can list multiple services/expertises. Each offering has:
- A service type (from the predefined list)
- A description (can be multilingual)

### Offering Format

**Single Language**:
```
## OFFERING: service-type
Description of this service.
Multiple lines supported.
```

**Multilanguage**:
```
## OFFERING: service-type
[EN]
Description in English.

[PT]
Descrição em Português.
```

### Multiple Offerings Example

```
## OFFERING: plumber
[EN]
Full plumbing services: pipe repair, leak detection, drain cleaning,
bathroom and kitchen installations. 15 years of experience.

[PT]
Serviços completos de canalização: reparação de tubos, deteção de fugas,
limpeza de esgotos, instalações de casa de banho e cozinha.

## OFFERING: hvac
[EN]
Heating, ventilation, and air conditioning installation and repair.
Certified technician for all major brands.

[PT]
Instalação e reparação de aquecimento, ventilação e ar condicionado.
Técnico certificado para todas as principais marcas.

## OFFERING: handyman
[EN]
General repairs and maintenance. No job too small!

[PT]
Reparações gerais e manutenção. Nenhum trabalho é pequeno demais!
```

### Service Type Constraints

- Must be from the predefined list (see [Service Types Reference](#service-types-reference))
- Lowercase with hyphens (e.g., `plumber`, `auto-electrician`, `web-developer`)
- Each type can only appear once per service provider
- At least one offering required

## Service Types Reference

### Overview

The service type field allows categorization for filtering and searching. Types are lowercase with hyphens separating words. Approximately 68 predefined types organized by 10 categories.

### Home & Property (12 types)

- **plumber**: Plumbing services (pipes, drains, fixtures)
- **electrician**: Electrical work (wiring, installations, repairs)
- **carpenter**: Carpentry and woodwork
- **painter**: Painting and decorating
- **roofer**: Roofing services
- **gardener**: Gardening and landscaping
- **cleaner**: House/office cleaning
- **handyman**: General repairs and maintenance
- **locksmith**: Lock and key services
- **pest-control**: Pest extermination
- **hvac**: Heating, ventilation, air conditioning
- **mover**: Moving and relocation services

### Automotive (6 types)

- **mechanic**: Auto repair and maintenance
- **auto-electrician**: Vehicle electrical systems
- **tow-service**: Towing and roadside assistance
- **car-wash**: Car washing and detailing
- **tire-service**: Tire repair and replacement
- **auto-body**: Body work and painting

### Personal Services (10 types)

- **tutor**: Private tutoring and lessons
- **nurse**: Nursing and healthcare
- **caregiver**: Elder/child care
- **personal-trainer**: Fitness training
- **massage-therapist**: Massage therapy
- **hairdresser**: Hair styling
- **barber**: Barber services
- **beautician**: Beauty treatments
- **tailor**: Tailoring and alterations
- **chef**: Personal chef services

### Professional Services (8 types)

- **lawyer**: Legal services
- **accountant**: Accounting and tax
- **notary**: Notarization services
- **translator**: Translation and interpretation
- **photographer**: Photography services
- **videographer**: Video production
- **graphic-designer**: Graphic design
- **web-developer**: Web development

### Technical Services (6 types)

- **it-support**: IT technical support
- **appliance-repair**: Appliance repair
- **phone-repair**: Mobile phone repair
- **computer-repair**: Computer repair
- **solar-installer**: Solar panel installation
- **security-systems**: Security system installation

### Events & Entertainment (4 types)

- **dj**: DJ services
- **musician**: Live music
- **event-planner**: Event planning
- **caterer**: Catering services

### Pet Services (4 types)

- **veterinarian**: Veterinary services
- **pet-groomer**: Pet grooming
- **pet-sitter**: Pet sitting
- **dog-walker**: Dog walking

### Creative & Arts (6 types)

- **artist**: Visual arts (painting, sculpture, drawing)
- **writer**: Writing services (copywriting, content, ghostwriting)
- **illustrator**: Illustration and digital art
- **animator**: Animation and motion graphics
- **voice-actor**: Voice acting and narration
- **art-teacher**: Art instruction and workshops

### Technology & Software (6 types)

- **programmer**: Software development and coding
- **mobile-developer**: Mobile app development (iOS, Android)
- **data-analyst**: Data analysis and visualization
- **ai-specialist**: AI/ML development and consulting
- **cybersecurity**: Cybersecurity consulting and auditing
- **devops**: DevOps and cloud infrastructure

### Security & Protection (6 types)

- **security-guard**: Security guard services
- **night-guard**: Night watchman and overnight security
- **bodyguard**: Personal protection and escort services
- **private-investigator**: Private investigation services
- **alarm-monitoring**: Alarm system monitoring services
- **access-control**: Access control and entry management

### Usage Guidelines

**Choosing Types**:
- Select all applicable service types
- Use lowercase with hyphens
- Providers can offer multiple types

**Examples**:
```
## OFFERING: plumber
## OFFERING: electrician
## OFFERING: handyman
```

## Contact Information

### Contact Fields Summary

| Field | Format | Example |
|-------|--------|---------|
| PHONE | International format recommended | `+351-912-345-678` |
| EMAIL | Standard email format | `contact@example.com` |
| WEBSITE | Full URL with https:// | `https://johnrepairs.pt` |

### Direct Messaging

All service providers can be contacted directly through Geogram's built-in messaging system:
- No external apps or accounts required
- Uses the provider's callsign (AUTHOR field)
- Encrypted 1:1 messaging

### Contact Display

UI should display contact options as actionable buttons:
- **Send Message**: Opens Geogram chat with provider (always available)
- **Call**: Opens phone dialer (if PHONE provided)
- **Email**: Opens email client (if EMAIL provided)
- **Website**: Opens web browser (if WEBSITE provided)

## Pricing Information

### Pricing Fields Summary

| Field | Format | Example | Description |
|-------|--------|---------|-------------|
| PRICE | Numeric value | `50` | Base price amount |
| CURRENCY | ISO 4217 code | `EUR`, `USD`, `GBP` | Currency code |
| PRICE_UNIT | `hour`, `day`, or `service` | `hour` | Billing unit |

### Price Unit Explained

- **hour**: Price per hour of work (common for consulting, repairs)
- **day**: Price per full day of work (common for contractors)
- **service**: Fixed price per job/service (common for specific tasks)

### Common Currency Codes

| Code | Currency | Symbol |
|------|----------|--------|
| EUR | Euro | € |
| USD | US Dollar | $ |
| GBP | British Pound | £ |
| BRL | Brazilian Real | R$ |
| CHF | Swiss Franc | CHF |
| JPY | Japanese Yen | ¥ |
| CNY | Chinese Yuan | ¥ |
| AUD | Australian Dollar | A$ |
| CAD | Canadian Dollar | C$ |

### Pricing Display

UI should format pricing as:
- `€50/hour` - Price per hour
- `$500/day` - Price per day
- `€200/service` - Fixed price per job

**Note**: Detailed or variable pricing can be explained in the ABOUT or OFFERING description sections.

## Service Radius

### Radius Purpose

The radius defines the geographic coverage area where the service provider operates:
- **Small radius** (1-10 km): Local neighborhood services
- **Medium radius** (10-50 km): City-wide services
- **Large radius** (50-200 km): Regional services

### Radius Constraints

**Minimum**: 1 kilometer
- Very local services
- Walking-distance providers

**Default**: 30 kilometers
- Typical city/metro area coverage
- Reasonable driving distance

**Maximum**: 200 kilometers
- Regional service providers
- Mobile services that travel far

**Format**: Integer value in kilometers
```
RADIUS: 1        # Very local
RADIUS: 10       # Neighborhood
RADIUS: 30       # Default (city)
RADIUS: 50       # Metro area
RADIUS: 100      # Regional
RADIUS: 200      # Maximum
```

### Radius Use Cases

**1-10 km**:
- Neighborhood handyman
- Local tutors
- Pet walkers
- Home cleaners

**10-50 km**:
- City-wide plumbers/electricians
- Photographers
- Mobile mechanics
- Event services

**50-200 km**:
- Specialized contractors
- Regional emergency services
- Traveling professionals
- Installation services

### Radius Display

**UI Considerations**:
- Display circle on map with specified radius
- Show coverage area visually
- Use for proximity searches ("services near me")
- Filter services by coverage of user's location

## Photos and Media

### Media Organization

Media files are stored in the `media/` subfolder:

```
X1ABCD_johns-plumbing-services/
├── service.txt
└── media/
    ├── media1.jpg          # Profile picture (if selected)
    ├── media2.jpg
    ├── media3.png
    └── media4.webp
```

### Supported Media Types

**Images**:
- JPG, JPEG, PNG, GIF, WebP, BMP
- Recommended: JPG for photos, PNG for graphics
- Any resolution (high resolution recommended)

**Videos** (optional):
- MP4, WebM, MOV
- Short clips recommended

### Profile Picture

**Selection**:
- User selects one media file from `media/` as profile picture
- Stored as relative path in `PROFILE_PIC` field
- Example: `PROFILE_PIC: media/media1.jpg`

**Display**:
- Shown prominently in service listings
- Used in search results
- Displayed in service detail header

### Media Naming

**Convention**: Sequential naming (media1.jpg, media2.jpg, etc.)

**Best Practices**:
- Use sequential numbering for simplicity
- Preserve original file extensions
- Keep all media in `media/` folder

## Feedback System

### Overview

Services use the **Centralized Feedback API** for likes, ratings, and comments.

**IMPORTANT**: For complete implementation details, file formats, API endpoints, NOSTR signing, and error handling, refer to the authoritative documentation:

> **[Centralized Feedback API Documentation](../API_feedback.md)**

This is the primary reference for implementing feedback functionality.

### Folder Structure

```
X1ABCD_johns-plumbing-services/
├── service.txt
├── media/
└── feedback/
    ├── likes.txt               # One npub per line
    ├── ratings.txt             # Ratings with required comments (JSON events)
    ├── subscribe.txt           # Subscribers
    └── comments/
        ├── 2025-12-28_10-30-00_X1ABCD.txt
        └── 2025-12-28_14-15-30_Y2EFGH.txt
```

### API Endpoints

Following the centralized feedback API pattern (see [API_feedback.md](../API_feedback.md)):

```
POST /api/feedback/service/{serviceId}/like
POST /api/feedback/service/{serviceId}/rating      # Rating with required comment
GET  /api/feedback/service/{serviceId}/rating      # Get all ratings
DELETE /api/feedback/service/{serviceId}/rating/{ratingId}  # Owner can delete
POST /api/feedback/service/{serviceId}/comment
GET  /api/feedback/service/{serviceId}
POST /api/feedback/service/{serviceId}/subscribe
```

### Ratings System

Ratings are a special feedback type that **require an associated comment**. Unlike simple likes, ratings provide detailed feedback with a 1-5 score.

**Key Features**:
- Rating must include a comment (cannot rate without explanation)
- Service provider can delete ratings they receive
- Ratings are stored in `feedback/ratings.txt` as signed NOSTR events
- Average rating calculated from all ratings

**Rating Scale**:
- **5**: Excellent, highly recommended
- **4**: Very good
- **3**: Good, average
- **2**: Below average
- **1**: Poor

**Example Rating Request** (see [API_feedback.md](../API_feedback.md) for full format):
```json
{
  "rating": 5,
  "comment": "Excellent electrician! Fixed all my issues in one visit.",
  "npub": "npub1xyz789...",
  "signature": "hex_signature"
}
```

### Rating Management

Service providers have special permissions to manage ratings on their services:

- **View all ratings**: See who rated and what they said
- **Delete ratings**: Remove inappropriate or unfair ratings
- **Respond to ratings**: Add comments in response (via regular comments)

When a provider deletes a rating, it is removed from `feedback/ratings.txt`. The deletion is logged for audit purposes.

### Comments (Without Rating)

Regular comments without ratings follow the standard format:

```
AUTHOR: X1ABCD
CREATED: 2025-12-28 10:30_00

Great service! John fixed my plumbing issue quickly and professionally.
Very reasonable pricing and excellent communication.

--> npub: npub1abc123...
--> signature: hex_signature
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

**Service Signature**:
```
--> npub: npub1qqqqqqqq...
--> signature: 0123456789abcdef...
```

### Signature Verification

1. Extract npub and signature from metadata
2. Reconstruct signable message content
3. Verify Schnorr signature
4. Display verification badge in UI if valid

## Complete Examples

### Example 1: Simple Service (Single Language, Single Offering)

**Folder**: `portugal/lisbon/X1ABCD_johns-plumbing-services/`

```
# SERVICE: John's Plumbing Services

CREATED: 2025-12-28 10:00_00
AUTHOR: X1ABCD
COORDINATES: 38.7223,-9.1393
RADIUS: 30
ADDRESS: Rua da Paz 123, Lisboa, Portugal
HOURS: Mon-Fri 8:00-18:00, Sat 9:00-13:00
PROFILE_PIC: media/media1.jpg

PHONE: +351-912-345-678
EMAIL: john.plumber@email.com

PRICE: 35
CURRENCY: EUR
PRICE_UNIT: hour

## ABOUT
Licensed plumber with 15 years of experience in the Lisbon area.
Specializing in residential and commercial plumbing services.

Fast, reliable, and affordable. Free quotes for all jobs.

## OFFERING: plumber
Complete plumbing services including:
- Pipe repair and replacement
- Leak detection and repair
- Drain cleaning
- Bathroom and kitchen installations
- Water heater installation and repair

Emergency services available 24/7.

--> npub: npub1abc123...
--> signature: 0123456789abcdef...
```

### Example 2: Multiple Services Provider (Multilanguage)

**Folder**: `united-states/new-york/Y2EFGH_marias-home-services/`

```
# SERVICE_EN: Maria's Home Services
# SERVICE_PT: Serviços Domésticos da Maria

CREATED: 2025-12-28 09:00_00
AUTHOR: Y2EFGH
COORDINATES: 40.7128,-74.0060
RADIUS: 50
ADDRESS: 123 Main Street, Queens, NY
HOURS: Mon-Sat 7:00-19:00
PROFILE_PIC: media/media1.jpg
ADMINS: npub1admin123...

PHONE: +1-555-123-4567
EMAIL: maria.homeservices@email.com
WEBSITE: https://mariahomeservices.com

PRICE: 45
CURRENCY: USD
PRICE_UNIT: hour

## ABOUT
[EN]
Professional home services provider serving the New York City metro area.
Family-owned business with over 20 years of experience.

We take pride in our work and treat every home like our own.
Fully licensed, bonded, and insured.

[PT]
Prestadora profissional de serviços domésticos na área metropolitana de Nova York.
Empresa familiar com mais de 20 anos de experiência.

Temos orgulho no nosso trabalho e tratamos cada casa como se fosse a nossa.
Totalmente licenciados, com fiança e seguros.

## OFFERING: cleaner
[EN]
Professional house and office cleaning services.

- Regular cleaning (weekly, bi-weekly, monthly)
- Deep cleaning
- Move-in/move-out cleaning
- Post-construction cleaning

Eco-friendly products available upon request.

[PT]
Serviços profissionais de limpeza de casas e escritórios.

- Limpeza regular (semanal, quinzenal, mensal)
- Limpeza profunda
- Limpeza de mudança
- Limpeza pós-obra

Produtos ecológicos disponíveis mediante pedido.

## OFFERING: gardener
[EN]
Landscaping and garden maintenance.

- Lawn mowing and edging
- Hedge trimming
- Flower bed maintenance
- Seasonal planting
- Garden design

[PT]
Paisagismo e manutenção de jardins.

- Corte e aparação de relva
- Poda de sebes
- Manutenção de canteiros
- Plantação sazonal
- Design de jardins

## OFFERING: handyman
[EN]
General repairs and small fixes around the house.
No job too small! From hanging pictures to fixing doors.

[PT]
Reparações gerais e pequenos arranjos pela casa.
Nenhum trabalho é pequeno demais! De pendurar quadros a arranjar portas.

--> npub: npub1xyz789...
--> signature: abcd1234efgh5678...
```

### Example 3: Professional Services

**Folder**: `portugal/lisbon/Z3IJKL_ana-silva-legal-services/`

```
# SERVICE_EN: Ana Silva - Legal Services
# SERVICE_PT: Ana Silva - Serviços Jurídicos
# SERVICE_ES: Ana Silva - Servicios Legales

CREATED: 2025-12-28 08:00_00
AUTHOR: Z3IJKL
COORDINATES: 38.7169,-9.1399
RADIUS: 100
ADDRESS: Av. da Liberdade 200, 1250-147 Lisboa
HOURS: Mon-Fri 9:00-18:00 (by appointment)
PROFILE_PIC: media/media1.jpg

PHONE: +351-213-456-789
EMAIL: ana.silva@lawfirm.pt
WEBSITE: https://anasilva-advogada.pt

PRICE: 100
CURRENCY: EUR
PRICE_UNIT: hour

## ABOUT
[EN]
Licensed attorney with 12 years of experience in Portuguese and EU law.
Member of the Portuguese Bar Association.

Specializing in business law, real estate transactions, and immigration matters.
Fluent in Portuguese, English, and Spanish.

[PT]
Advogada licenciada com 12 anos de experiência em direito português e europeu.
Membro da Ordem dos Advogados.

Especializada em direito empresarial, transações imobiliárias e assuntos de imigração.
Fluente em português, inglês e espanhol.

[ES]
Abogada licenciada con 12 años de experiencia en derecho portugués y europeo.
Miembro del Colegio de Abogados de Portugal.

Especializada en derecho empresarial, transacciones inmobiliarias y asuntos de inmigración.
Fluida en portugués, inglés y español.

## OFFERING: lawyer
[EN]
General legal services including:
- Business formation and contracts
- Real estate transactions
- Immigration and visa applications
- Civil litigation
- Legal consultations

Initial consultation: 30 minutes free.

[PT]
Serviços jurídicos gerais incluindo:
- Constituição de empresas e contratos
- Transações imobiliárias
- Imigração e pedidos de visto
- Litígios civis
- Consultas jurídicas

Consulta inicial: 30 minutos grátis.

[ES]
Servicios legales generales incluyendo:
- Constitución de empresas y contratos
- Transacciones inmobiliarias
- Inmigración y solicitudes de visa
- Litigios civiles
- Consultas legales

Consulta inicial: 30 minutos gratis.

## OFFERING: notary
[EN]
Notarization services for documents, contracts, and legal papers.
Certified translations between Portuguese, English, and Spanish.

[PT]
Serviços de reconhecimento notarial para documentos, contratos e papéis legais.
Traduções certificadas entre português, inglês e espanhol.

[ES]
Servicios de notarización para documentos, contratos y papeles legales.
Traducciones certificadas entre portugués, inglés y español.

## OFFERING: translator
[EN]
Certified legal translations:
- Portuguese ↔ English
- Portuguese ↔ Spanish
- English ↔ Spanish

Official sworn translations available for legal documents.

[PT]
Traduções jurídicas certificadas:
- Português ↔ Inglês
- Português ↔ Espanhol
- Inglês ↔ Espanhol

Traduções juramentadas disponíveis para documentos legais.

--> npub: npub1legal123...
--> signature: fedcba987654...
```

### Example 4: Technical Services

**Folder**: `united-kingdom/london/A4MNOP_techfix-pro-mobile-computer-repair/`

```
# SERVICE: TechFix Pro - Mobile & Computer Repair

CREATED: 2025-12-28 11:00_00
AUTHOR: A4MNOP
COORDINATES: 51.5074,-0.1278
RADIUS: 25
ADDRESS: 45 Oxford Street, London W1D 2DZ
HOURS: Mon-Sat 10:00-19:00, Sun 12:00-17:00
PROFILE_PIC: media/media1.jpg

PHONE: +44-20-1234-5678
EMAIL: info@techfixpro.co.uk
WEBSITE: https://techfixpro.co.uk

PRICE: 50
CURRENCY: GBP
PRICE_UNIT: service

## ABOUT
Your one-stop shop for all mobile and computer repairs in Central London.
Certified technicians with 10+ years of experience.

Same-day repairs available for most issues.
All repairs come with 90-day warranty.

## OFFERING: phone-repair
Mobile phone repair services for all brands:

iPhone:
- Screen replacement (30 min)
- Battery replacement (20 min)
- Charging port repair
- Camera repair

Android (Samsung, Google, OnePlus, etc.):
- Screen replacement
- Battery replacement
- Software issues

Walk-ins welcome. No appointment needed.

## OFFERING: computer-repair
Laptop and desktop computer repairs:

- Hardware repairs (screen, keyboard, motherboard)
- Virus and malware removal
- Data recovery
- Operating system reinstallation
- Upgrade services (RAM, SSD)

Free diagnostics for all repairs.

## OFFERING: it-support
IT support for small businesses and home users:

- Network setup and troubleshooting
- WiFi optimization
- Smart home setup
- Remote support available
- Regular maintenance plans

Monthly support packages available starting at £50/month.

--> npub: npub1tech456...
--> signature: 111222333444...
```

## Parsing Implementation

### Service File Parsing

```
1. Read service.txt as UTF-8 text
2. Parse title lines:
   - Single language: "# SERVICE: <name>"
   - Multilanguage: "# SERVICE_XX: <name>"
   - Extract all language variants into Map<String, String>
3. Verify at least one title exists
4. Parse header lines:
   - CREATED: timestamp
   - AUTHOR: callsign
   - COORDINATES: lat,lon (mandatory)
   - RADIUS: kilometers (1-200, default 30)
   - ADDRESS: (optional)
   - HOURS: (optional)
   - PROFILE_PIC: (optional)
   - ADMINS: (optional)
5. Parse contact lines:
   - PHONE, EMAIL, WEBSITE
6. Parse pricing lines:
   - PRICE: numeric value
   - CURRENCY: ISO 4217 code
   - PRICE_UNIT: hour/day/service
7. Parse ABOUT section:
   - Single language: Read after "## ABOUT"
   - Multilanguage: Look for [XX] markers
8. Parse OFFERING sections:
   - Look for "## OFFERING: <type>" headers
   - Extract type and description for each
   - Support multilanguage descriptions
9. Extract metadata (npub, signature)
10. Validate signature placement (must be last)
```

### City Lookup

```
1. Extract coordinates from COORDINATES field
2. Query internal city database for nearest city
3. Retrieve city name and country
4. Sanitize names (lowercase, hyphens)
5. Format folder path: {country}/{city}/
6. Verify service folder is in correct location
```

### Offering Parsing

```
1. Find all "## OFFERING: <type>" headers
2. For each offering:
   a. Extract service type (lowercase with hyphens)
   b. Validate type is in predefined list
   c. Extract description:
      - Single language: Text until next ## or metadata
      - Multilanguage: Parse [XX] blocks
   d. Create ServiceOffering object
3. Validate at least one offering exists
```

## File Operations

### Creating a Service

```
1. Verify coordinates are provided (mandatory)
2. Query city database for nearest city/village
3. Get country and city names
4. Sanitize country name: lowercase, spaces to hyphens
5. Sanitize city name: lowercase, spaces to hyphens
6. Sanitize service name
7. Generate folder name: {CALLSIGN}_{sanitized-name}/
8. Create country directory if needed
9. Create city directory if needed
10. Create service folder
11. Create media/ subdirectory
12. Create service.txt with header, about, and offerings
13. Create feedback/ subdirectory
14. Set folder permissions (755)
```

### Adding Media

```
1. Verify service exists
2. Copy file(s) to media/ folder
3. Use sequential naming (media1.jpg, media2.jpg, etc.)
4. Set file permissions (644)
5. Optionally update PROFILE_PIC field
```

### Setting Profile Picture

```
1. Verify media file exists in media/ folder
2. Update PROFILE_PIC field in service.txt
3. Use relative path (e.g., "media/media1.jpg")
```

### Deleting a Service

```
1. Verify user has permission (creator or admin)
2. Recursively delete service folder:
   - service.txt
   - media/ directory
   - feedback/ directory
3. Check if city folder is empty:
   - If empty, optionally delete city folder
4. Check if country folder is empty:
   - If empty, optionally delete country folder
```

## Validation Rules

### Service Validation

- [x] First line must start with `# SERVICE: ` or `# SERVICE_XX: `
- [x] At least one title required
- [x] Language codes must be two letters, uppercase
- [x] Name must not be empty
- [x] CREATED line must have valid timestamp
- [x] AUTHOR line must have non-empty callsign
- [x] COORDINATES must be valid lat,lon (mandatory)
- [x] RADIUS must be integer 1-200 (default 30)
- [x] At least one offering required
- [x] Each offering type must be from predefined list
- [x] Signature must be last metadata if present
- [x] Folder name must match {CALLSIGN}_{name} pattern
- [x] Service folder must be in correct country/city folder

### Contact Validation

- [ ] PHONE: Any format (international recommended)
- [ ] EMAIL: Valid email format
- [ ] WEBSITE: Valid URL (https:// recommended)

### Pricing Validation

- [ ] PRICE: Numeric value > 0
- [ ] CURRENCY: Valid ISO 4217 code (EUR, USD, GBP, etc.)
- [ ] PRICE_UNIT: Must be "hour", "day", or "service"
- [ ] If PRICE set, CURRENCY and PRICE_UNIT required

### Offering Validation

- [x] Type must be from predefined list
- [x] Type must be lowercase with hyphens
- [x] At least one description line required
- [x] Multilanguage descriptions must use [XX] format

### Coordinate Validation

**Coordinates (Mandatory)**:
- Latitude: -90.0 to +90.0
- Longitude: -180.0 to +180.0
- Format: `lat,lon` (no spaces)
- Used to determine city/country placement

## Best Practices

### For Service Providers

1. **Accurate Location**: Use precise coordinates for your base (mandatory)
2. **Set Pricing**: Add clear pricing information
3. **Clear Descriptions**: Write detailed, professional descriptions
4. **Quality Photos**: Upload clear, professional images
5. **Set Profile Picture**: Choose your best photo as profile
6. **Realistic Radius**: Set radius to actual service area
7. **Multiple Offerings**: List all services you provide
8. **Multilingual**: Add translations to reach more clients
9. **Update Hours**: Keep operating hours current
10. **Sign Your Profile**: Use NOSTR signature for trust
11. **Respond to Messages**: Use built-in messaging to communicate with clients

### For Developers

1. **Validate Input**: Check coordinates, radius, and types
2. **City Lookup**: Use city database to determine folder structure
3. **Handle Multilingual**: Implement fallback (requested → EN → first)
4. **Atomic Operations**: Use temp files for updates
5. **Permission Checks**: Verify user rights
6. **Map Integration**: Show service areas on maps
7. **Search by Type**: Enable filtering by service types
8. **Proximity Search**: Find services covering user's location
9. **Direct Messaging**: Integrate with chat system for messaging

## Security Considerations

### Access Control

**Service Creator**:
- Edit service.txt
- Delete service
- Add/remove photos
- Moderate comments

**Admins**:
- Same as creator
- Can be added/removed by creator

### Location Privacy

**Coordinate Considerations**:
- Use office/business location, not home
- Consider using approximate location
- Radius provides some privacy buffer

### Contact Privacy

**Best Practices**:
- Use business phone, not personal
- Use business email
- Create dedicated social media accounts
- Website provides professional front

## Related Documentation

- [Places Format Specification](places-format-specification.md)
- [Alert Format Specification](alert-format-specification.md)
- [Centralized Feedback API](../API_feedback.md)
- [NOSTR Protocol](https://github.com/nostr-protocol/nostr)

## Change Log

### Version 1.1 (2025-12-28)

**Major Changes**:
- Changed folder organization from coordinate-based to country/city-based
- Folder structure: `{country}/{city}/{CALLSIGN}_{name}/`
- City determined by matching coordinates to internal city database
- Location (COORDINATES) is now mandatory
- Removed social media contact fields (WhatsApp, Instagram, Facebook)
- Added built-in direct messaging via Geogram chat
- Added pricing fields (PRICE, CURRENCY, PRICE_UNIT)

**New Service Types**:
- Creative & Arts: artist, writer, illustrator, animator, voice-actor, art-teacher
- Technology & Software: programmer, mobile-developer, data-analyst, ai-specialist, cybersecurity, devops
- Security & Protection: security-guard, night-guard, bodyguard, private-investigator, alarm-monitoring, access-control

**Total service types**: ~68 across 10 categories

### Version 1.0 (2025-12-28)

**Initial Specification**:
- Coordinate-based organization with ~30,000 regions
- Service provider profiles with multiple offerings
- ~50 predefined service types across 7 categories
- Multilingual support (11 languages)
- Contact information (phone, email, social media)
- Service radius (1-200 km)
- Profile picture selection
- Centralized feedback integration
- NOSTR signature support
