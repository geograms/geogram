# Service Format Specification

**Version**: 1.0
**Last Updated**: 2025-12-28
**Status**: Draft

## Table of Contents

- [Overview](#overview)
- [File Organization](#file-organization)
- [Coordinate-Based Organization](#coordinate-based-organization)
- [Service Format](#service-format)
- [Service Offerings](#service-offerings)
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
- **Coordinate-Based Organization**: Services organized by geographic regions
- **Service Radius**: Define geographic coverage area (1-200 km, default 30 km)
- **Multilingual Content**: Names and descriptions switch based on client language
- **Contact Information**: Phone, email, and social media links
- **Operating Hours**: Optional schedule field
- **Profile Picture**: Select one photo as the provider's profile image
- **Feedback Integration**: Uses centralized feedback API (likes, comments)
- **NOSTR Integration**: Cryptographic signatures for authenticity
- **~50 Predefined Service Types**: Categorized professions for easy filtering

### Use Cases

- Local mechanics advertising their services
- Freelance professionals (tutors, photographers, designers)
- Home service providers (plumbers, electricians, cleaners)
- Personal care services (hairdressers, massage therapists)
- Professional services (lawyers, accountants, notaries)

## File Organization

### Directory Structure

```
devices/{callsign}/services/
├── 38.7_-9.1/                              # Region folder (1 decimal precision)
│   └── 38.7223_-9.1393_john-repairs/
│       ├── service.txt                      # Main service file
│       ├── images/                          # Photo storage
│       │   ├── photo1.jpg
│       │   └── photo2.jpg
│       └── feedback/                        # Centralized feedback
│           ├── likes.txt
│           ├── subscribe.txt
│           └── comments/
│               └── 2025-12-28_10-30-00_Y2EFGH.txt
└── 40.7_-74.0/                             # Another region
    └── 40.7128_-74.0060_maria-tutoring/
        ├── service.txt
        └── images/
```

### Region Folder Naming

**Pattern**: `{LAT}_{LON}/`

**Coordinate Rounding**:
- Round latitude to 1 decimal place (e.g., 38.7223 → 38.7)
- Round longitude to 1 decimal place (e.g., -9.1393 → -9.1)
- Creates ~30,000 possible regions globally
- Each region covers approximately 130 km x 130 km at the equator

**Examples**:
```
38.7_-9.1/          # Lisbon area, Portugal
40.7_-74.0/         # New York City area, USA
51.5_-0.1/          # London area, UK
-33.8_151.2/        # Sydney area, Australia
35.6_139.6/         # Tokyo area, Japan
```

### Service Folder Naming

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
Name: "John's Repair Services"
Coordinates: 38.7223, -9.1393
→ 38.7223_-9.1393_johns-repair-services/

Name: "Maria's Tutoring & Teaching"
Coordinates: 40.7128, -74.0060
→ 40.7128_-74.0060_marias-tutoring-teaching/
```

## Coordinate-Based Organization

### Grid System Overview

The services collection uses a two-level coordinate-based organization:

1. **Region Level**: Rounded coordinates (1 decimal place)
   - Purpose: Group nearby services into manageable folders
   - Limit: ~30,000 regions globally
   - Size: ~130 km x 130 km per region

2. **Service Level**: Full precision coordinates (6 decimals)
   - Purpose: Exact location identification (office/base location)
   - Precision: ~0.1 meters (at equator)

### Finding a Service's Region

```
Given coordinates: 38.7223, -9.1393

1. Round latitude to 1 decimal: 38.7223 → 38.7
2. Round longitude to 1 decimal: -9.1393 → -9.1
3. Format region folder: 38.7_-9.1/
4. Service created in: 38.7_-9.1/38.7223_-9.1393_service-name/
```

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
PROFILE_PIC: images/photo1.jpg (optional)
ADMINS: npub1abc123... (optional)

PHONE: +351-912-345-678 (optional)
EMAIL: contact@example.com (optional)
WHATSAPP: +351-912-345-678 (optional)
INSTAGRAM: @username (optional)
FACEBOOK: /pagename (optional)
WEBSITE: https://example.com (optional)

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
PROFILE_PIC: images/photo1.jpg (optional)
ADMINS: npub1abc123... (optional)

PHONE: +351-912-345-678
EMAIL: contact@example.com
WHATSAPP: +351-912-345-678
INSTAGRAM: @username
FACEBOOK: /pagename
WEBSITE: https://example.com

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
   - **Example**: `PROFILE_PIC: images/photo1.jpg`
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

13. **WhatsApp** (optional)
    - **Format**: `WHATSAPP: <phone number>`
    - **Example**: `WHATSAPP: +351-912-345-678`
    - **Note**: Can be same as PHONE or different

14. **Instagram** (optional)
    - **Format**: `INSTAGRAM: <handle>`
    - **Example**: `INSTAGRAM: @johnrepairs`

15. **Facebook** (optional)
    - **Format**: `FACEBOOK: <page path>`
    - **Example**: `FACEBOOK: /johnrepairs`

16. **Website** (optional)
    - **Format**: `WEBSITE: <url>`
    - **Example**: `WEBSITE: https://johnrepairs.pt`

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

The service type field allows categorization for filtering and searching. Types are lowercase with hyphens separating words. Approximately 50 predefined types organized by category.

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
| WHATSAPP | Phone number with country code | `+351-912-345-678` |
| INSTAGRAM | Handle with @ | `@johnrepairs` |
| FACEBOOK | Page path with / | `/johnrepairs` |
| WEBSITE | Full URL with https:// | `https://johnrepairs.pt` |

### Contact Display

UI should display contact options as actionable buttons:
- **Phone**: Opens phone dialer
- **Email**: Opens email client
- **WhatsApp**: Opens WhatsApp with pre-filled number
- **Instagram**: Opens Instagram profile
- **Facebook**: Opens Facebook page
- **Website**: Opens web browser

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

### Photo Organization

Photos are stored in the `images/` subfolder:

```
38.7223_-9.1393_john-repairs/
├── service.txt
└── images/
    ├── photo1.jpg          # Profile picture (if selected)
    ├── photo2.jpg
    ├── photo3.png
    └── photo4.webp
```

### Supported Media Types

**Images**:
- JPG, JPEG, PNG, GIF, WebP, BMP
- Recommended: JPG for photos, PNG for graphics
- Any resolution (high resolution recommended)

### Profile Picture

**Selection**:
- User selects one photo from `images/` as profile picture
- Stored as relative path in `PROFILE_PIC` field
- Example: `PROFILE_PIC: images/photo1.jpg`

**Display**:
- Shown prominently in service listings
- Used in search results
- Displayed in service detail header

### Photo Naming

**Convention**: Sequential naming (photo1.jpg, photo2.jpg, etc.)

**Best Practices**:
- Use sequential numbering for simplicity
- Preserve original file extensions
- Keep photos in `images/` folder

## Feedback System

### Overview

Services use the centralized feedback API for likes and comments. Feedback is stored in the `feedback/` subdirectory.

### Folder Structure

```
38.7223_-9.1393_john-repairs/
├── service.txt
├── images/
└── feedback/
    ├── likes.txt               # One npub per line
    ├── subscribe.txt           # Subscribers
    └── comments/
        ├── 2025-12-28_10-30-00_X1ABCD.txt
        └── 2025-12-28_14-15-30_Y2EFGH.txt
```

### API Endpoints

Following the centralized feedback API pattern:

```
POST /api/feedback/service/{serviceId}/like
POST /api/feedback/service/{serviceId}/comment
GET  /api/feedback/service/{serviceId}
POST /api/feedback/service/{serviceId}/subscribe
```

### Comment Format

Comments follow the standard feedback format:

```
AUTHOR: X1ABCD
CREATED: 2025-12-28 10:30_00

Great service! John fixed my plumbing issue quickly and professionally.
Very reasonable pricing and excellent communication.

--> npub: npub1abc123...
--> signature: hex_signature
```

### Ratings in Comments

Comments can include optional ratings:

```
AUTHOR: Y2EFGH
CREATED: 2025-12-28 14:15_30

Excellent electrician! Fixed all my issues in one visit.
--> rating: 5
--> npub: npub1xyz789...
--> signature: hex_signature
```

**Rating Scale**:
- **5**: Excellent, highly recommended
- **4**: Very good
- **3**: Good, average
- **2**: Below average
- **1**: Poor

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

```
# SERVICE: John's Plumbing Services

CREATED: 2025-12-28 10:00_00
AUTHOR: X1ABCD
COORDINATES: 38.7223,-9.1393
RADIUS: 30
ADDRESS: Rua da Paz 123, Lisboa, Portugal
HOURS: Mon-Fri 8:00-18:00, Sat 9:00-13:00
PROFILE_PIC: images/photo1.jpg

PHONE: +351-912-345-678
EMAIL: john.plumber@email.com
WHATSAPP: +351-912-345-678

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

```
# SERVICE_EN: Maria's Home Services
# SERVICE_PT: Serviços Domésticos da Maria

CREATED: 2025-12-28 09:00_00
AUTHOR: Y2EFGH
COORDINATES: 40.7128,-74.0060
RADIUS: 50
ADDRESS: 123 Main Street, Queens, NY
HOURS: Mon-Sat 7:00-19:00
PROFILE_PIC: images/photo1.jpg
ADMINS: npub1admin123...

PHONE: +1-555-123-4567
EMAIL: maria.homeservices@email.com
WHATSAPP: +1-555-123-4567
INSTAGRAM: @mariahomeservices
FACEBOOK: /mariahomeservices
WEBSITE: https://mariahomeservices.com

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
PROFILE_PIC: images/photo1.jpg

PHONE: +351-213-456-789
EMAIL: ana.silva@lawfirm.pt
WEBSITE: https://anasilva-advogada.pt

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

```
# SERVICE: TechFix Pro - Mobile & Computer Repair

CREATED: 2025-12-28 11:00_00
AUTHOR: A4MNOP
COORDINATES: 51.5074,-0.1278
RADIUS: 25
ADDRESS: 45 Oxford Street, London W1D 2DZ
HOURS: Mon-Sat 10:00-19:00, Sun 12:00-17:00
PROFILE_PIC: images/photo1.jpg

PHONE: +44-20-1234-5678
EMAIL: info@techfixpro.co.uk
WHATSAPP: +44-7700-900123
INSTAGRAM: @techfixpro_london
WEBSITE: https://techfixpro.co.uk

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
   - COORDINATES: lat,lon
   - RADIUS: kilometers (1-200, default 30)
   - ADDRESS: (optional)
   - HOURS: (optional)
   - PROFILE_PIC: (optional)
   - ADMINS: (optional)
5. Parse contact lines:
   - PHONE, EMAIL, WHATSAPP, INSTAGRAM, FACEBOOK, WEBSITE
6. Parse ABOUT section:
   - Single language: Read after "## ABOUT"
   - Multilanguage: Look for [XX] markers
7. Parse OFFERING sections:
   - Look for "## OFFERING: <type>" headers
   - Extract type and description for each
   - Support multilanguage descriptions
8. Extract metadata (npub, signature)
9. Validate signature placement (must be last)
```

### Region Calculation

```
1. Extract coordinates from COORDINATES field
2. Round latitude to 1 decimal place
3. Round longitude to 1 decimal place
4. Format region folder: {LAT}_{LON}/
5. Verify service folder is in correct region
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
1. Sanitize service name
2. Generate folder name: {lat}_{lon}_{sanitized-name}/
3. Calculate region from coordinates (round to 1 decimal)
4. Create region directory if needed: {LAT}_{LON}/
5. Create service folder
6. Create images/ subdirectory
7. Create service.txt with header, about, and offerings
8. Create feedback/ subdirectory
9. Set folder permissions (755)
```

### Adding Photos

```
1. Verify service exists
2. Copy photo(s) to images/ folder
3. Use sequential naming (photo1.jpg, photo2.jpg, etc.)
4. Set file permissions (644)
5. Optionally update PROFILE_PIC field
```

### Setting Profile Picture

```
1. Verify photo exists in images/ folder
2. Update PROFILE_PIC field in service.txt
3. Use relative path (e.g., "images/photo1.jpg")
```

### Deleting a Service

```
1. Verify user has permission (creator or admin)
2. Recursively delete service folder:
   - service.txt
   - images/ directory
   - feedback/ directory
3. Check if region folder is empty:
   - If empty, optionally delete region
```

## Validation Rules

### Service Validation

- [x] First line must start with `# SERVICE: ` or `# SERVICE_XX: `
- [x] At least one title required
- [x] Language codes must be two letters, uppercase
- [x] Name must not be empty
- [x] CREATED line must have valid timestamp
- [x] AUTHOR line must have non-empty callsign
- [x] COORDINATES must be valid lat,lon
- [x] RADIUS must be integer 1-200 (default 30)
- [x] At least one offering required
- [x] Each offering type must be from predefined list
- [x] Signature must be last metadata if present
- [x] Folder name must match {lat}_{lon}_* pattern
- [x] Service folder must be in correct region folder

### Contact Validation

- [ ] PHONE: Any format (international recommended)
- [ ] EMAIL: Valid email format
- [ ] WHATSAPP: Phone number format
- [ ] INSTAGRAM: Handle format (with or without @)
- [ ] FACEBOOK: Page path (with or without /)
- [ ] WEBSITE: Valid URL (https:// recommended)

### Offering Validation

- [x] Type must be from predefined list
- [x] Type must be lowercase with hyphens
- [x] At least one description line required
- [x] Multilanguage descriptions must use [XX] format

### Coordinate Validation

**Full Precision (Service)**:
- Latitude: -90.0 to +90.0
- Longitude: -180.0 to +180.0
- Format: `lat,lon` (no spaces)

**Rounded (Region)**:
- Latitude: 1 decimal place
- Longitude: 1 decimal place

## Best Practices

### For Service Providers

1. **Complete Profile**: Fill in all contact methods you use
2. **Clear Descriptions**: Write detailed, professional descriptions
3. **Quality Photos**: Upload clear, professional images
4. **Set Profile Picture**: Choose your best photo as profile
5. **Accurate Location**: Use precise coordinates for your base
6. **Realistic Radius**: Set radius to actual service area
7. **Multiple Offerings**: List all services you provide
8. **Multilingual**: Add translations to reach more clients
9. **Update Hours**: Keep operating hours current
10. **Sign Your Profile**: Use NOSTR signature for trust

### For Developers

1. **Validate Input**: Check coordinates, radius, and types
2. **Region Calculation**: Ensure correct region placement
3. **Handle Multilingual**: Implement fallback (requested → EN → first)
4. **Atomic Operations**: Use temp files for updates
5. **Permission Checks**: Verify user rights
6. **Map Integration**: Show service areas on maps
7. **Search by Type**: Enable filtering by service types
8. **Proximity Search**: Find services covering user's location

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
