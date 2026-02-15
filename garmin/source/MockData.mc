/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Mock data for simulator testing.
 * Set DEBUG_MOCK = true to pre-load DataStore with test data.
 * Set to false before building for device.
 */

import Toybox.Lang;

module MockData {

    // Toggle this to enable/disable mock data
    const DEBUG_MOCK = true;

    // Simulated GPS position: downtown Lisbon
    const MOCK_LAT = 38.7223d;
    const MOCK_LON = -9.1393d;

    //! Load all mock data into DataStore
    function load() as Void {
        if (!DEBUG_MOCK) {
            return;
        }

        // Mock GPS position
        DataStore.setLastPosition(MOCK_LAT, MOCK_LON);

        // Mock alerts
        DataStore.setAlerts([
            {
                "id" => "a1",
                "title" => "Flash Flood Warning",
                "description" => "Heavy rainfall expected in low-lying areas near the Tagus river. Avoid underground parking and riverside walkways.",
                "severity" => "emergency",
                "type" => "weather",
                "latitude" => 38.7075d,
                "longitude" => -9.1365d
            },
            {
                "id" => "a2",
                "title" => "Road Closure A5",
                "description" => "Major accident on A5 motorway near Oeiras exit. Expect delays of 45+ minutes.",
                "severity" => "urgent",
                "type" => "traffic",
                "latitude" => 38.6953d,
                "longitude" => -9.3147d
            },
            {
                "id" => "a3",
                "title" => "Air Quality Advisory",
                "description" => "Elevated PM2.5 levels detected in the Baixa district. Sensitive groups should limit outdoor activity.",
                "severity" => "attention",
                "type" => "environment",
                "latitude" => 38.7139d,
                "longitude" => -9.1394d
            },
            {
                "id" => "a4",
                "title" => "Missing Person",
                "description" => "Elderly male, 78, last seen near Rossio station wearing a blue jacket. Contact authorities if spotted.",
                "severity" => "urgent",
                "type" => "community",
                "latitude" => 38.7148d,
                "longitude" => -9.1387d
            },
            {
                "id" => "a5",
                "title" => "Power Outage Reported",
                "description" => "Grid section 14B offline. Estimated restoration in 2 hours. Affects Alfama neighborhood.",
                "severity" => "info",
                "type" => "infrastructure",
                "latitude" => 38.7118d,
                "longitude" => -9.1302d
            }
        ]);

        // Mock places
        DataStore.setPlaces([
            {
                "id" => "p1",
                "name" => "Lisbon Ham Radio Club",
                "description" => "CT1REP repeater site. Open meetings Thursdays at 20:00. VHF/UHF equipment available.",
                "type" => "repeater",
                "address" => "Rua da Prata 28, Lisboa",
                "latitude" => 38.7105d,
                "longitude" => -9.1370d
            },
            {
                "id" => "p2",
                "name" => "Emergency Shelter Belem",
                "description" => "Red Cross emergency shelter. Capacity 200. Water and first aid available.",
                "type" => "shelter",
                "address" => "Praca do Imperio, Belem",
                "latitude" => 38.6966d,
                "longitude" => -9.2057d
            },
            {
                "id" => "p3",
                "name" => "Geogram Node Parque",
                "description" => "Solar-powered mesh node on hilltop. LoRa + WiFi backhaul. Uptime 99.2%.",
                "type" => "node",
                "latitude" => 38.7283d,
                "longitude" => -9.1534d
            },
            {
                "id" => "p4",
                "name" => "Water Distribution Point",
                "description" => "Municipal emergency water point. Operational during alerts. Bring own containers.",
                "type" => "resource",
                "address" => "Largo do Carmo, Lisboa",
                "latitude" => 38.7122d,
                "longitude" => -9.1408d
            },
            {
                "id" => "p5",
                "name" => "Cascais Marina Relay",
                "description" => "VHF marine relay station. Channel 16 monitoring. Solar + battery backup.",
                "type" => "repeater",
                "latitude" => 38.6920d,
                "longitude" => -9.4190d
            }
        ]);

        // Mock chat rooms
        DataStore.setChatRooms([
            {
                "id" => "r1",
                "name" => "Lisbon Emergency Net",
                "type" => "emergency",
                "memberCount" => 47,
                "messageCount" => 312,
                "lastActivity" => "2026-02-15T14:30:00Z"
            },
            {
                "id" => "r2",
                "name" => "CT1REP Repeater Chat",
                "type" => "general",
                "memberCount" => 23,
                "messageCount" => 89,
                "lastActivity" => "2026-02-15T13:15:00Z"
            },
            {
                "id" => "r3",
                "name" => "Mesh Network Status",
                "type" => "technical",
                "memberCount" => 12,
                "messageCount" => 156,
                "lastActivity" => "2026-02-15T12:45:00Z"
            }
        ]);

        // Mock station URLs
        DataStore.setStationUrls([
            "https://p2p.radio",
            "https://lisbon.geogram.net",
            "http://192.168.1.100:8080"
        ] as Array<String>);
    }

    //! Return mock chat messages for a given room ID
    function getChatMessages(roomId as String) as Array {
        if (roomId.equals("r1")) {
            return [
                { "author" => "CT1ABC", "timestamp" => "14:30", "content" => "Flood waters receding near Cais do Sodre. Road passable now." },
                { "author" => "CT1DEF", "timestamp" => "14:22", "content" => "Confirmed. I drove through 10 min ago. Still wet but no standing water." },
                { "author" => "CT1GHI", "timestamp" => "14:15", "content" => "Shelter at Belem still accepting people. About 40 currently here." },
                { "author" => "CT1ABC", "timestamp" => "14:02", "content" => "Power restored in Alfama sector. Streetlights back on." },
                { "author" => "CT1JKL", "timestamp" => "13:48", "content" => "Anyone have eyes on the Tagus water level at Terreiro do Paco?" },
                { "author" => "CT1DEF", "timestamp" => "13:40", "content" => "River level dropping. Down 15cm from peak. Tide turning." },
                { "author" => "CT1MNO", "timestamp" => "13:25", "content" => "Red Cross convoy heading to Baixa with supplies. ETA 20 min." }
            ];
        } else if (roomId.equals("r2")) {
            return [
                { "author" => "CT1PQR", "timestamp" => "13:15", "content" => "Repeater is back online after the power cut. All bands operational." },
                { "author" => "CT1STU", "timestamp" => "13:02", "content" => "Good signal from my QTH in Sintra. S7 on 145.600." },
                { "author" => "CT1ABC", "timestamp" => "12:50", "content" => "Anyone planning to join the Sunday morning net?" },
                { "author" => "CT1VWX", "timestamp" => "12:35", "content" => "I will be there. Testing new Yagi antenna this weekend." }
            ];
        } else if (roomId.equals("r3")) {
            return [
                { "author" => "node-ops", "timestamp" => "12:45", "content" => "Node Parque back online. Battery was at 12% during outage, now charging." },
                { "author" => "CT1DEF", "timestamp" => "12:30", "content" => "Cascais relay showing intermittent drops. Might be antenna ice." },
                { "author" => "node-ops", "timestamp" => "12:15", "content" => "All 5 Lisbon nodes green. Mesh throughput nominal at 48kbps avg." },
                { "author" => "CT1GHI", "timestamp" => "11:58", "content" => "Deployed temp node at Rossio for the emergency. Battery good for 8hrs." },
                { "author" => "node-ops", "timestamp" => "11:45", "content" => "Network map updated. 23 active nodes in greater Lisbon area." }
            ];
        }
        return [];
    }
}
