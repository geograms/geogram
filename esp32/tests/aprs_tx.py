#!/usr/bin/env python3
"""
APRS TX via HackRF One — transmit an APRS packet on 144.800 MHz.

Can also output raw audio WAV (for Direwolf validation) or baseband IQ.

Usage:
  python3 aprs_tx.py                          # TX via HackRF
  python3 aprs_tx.py --wav out.wav            # WAV file only (for Direwolf)
  python3 aprs_tx.py --iq out.iq8             # IQ file only
  python3 aprs_tx.py --message "Test 123"     # Custom message
  python3 aprs_tx.py --dest X3XU3F --src HCKRF0
"""

import argparse
import struct
import subprocess
import sys
import tempfile

import numpy as np


# --- AX.25 ---

def ax25_encode_address(callsign: str, ssid: int = 0, last: bool = False) -> bytes:
    """Encode a callsign into AX.25 address field (7 bytes)."""
    call = callsign.upper().ljust(6)[:6]
    out = bytearray()
    for ch in call:
        out.append(ord(ch) << 1)
    ssid_byte = 0x60 | ((ssid & 0x0F) << 1)
    if last:
        ssid_byte |= 0x01
    out.append(ssid_byte)
    return bytes(out)


def ax25_build_ui_frame(dest: str, src: str, path: list, info: bytes) -> bytes:
    """Build an AX.25 UI frame (no FCS yet)."""
    frame = bytearray()
    frame += ax25_encode_address(dest, 0, last=(not path and True) or False)
    if path:
        frame += ax25_encode_address(src, 0, last=False)
        for i, relay in enumerate(path):
            parts = relay.split('-')
            call = parts[0]
            ssid = int(parts[1]) if len(parts) > 1 else 0
            frame += ax25_encode_address(call, ssid, last=(i == len(path) - 1))
    else:
        frame += ax25_encode_address(src, 0, last=True)
    frame += bytes([0x03, 0xF0])  # Control=UI, PID=no layer 3
    frame += info
    return bytes(frame)


def ax25_fcs(data: bytes) -> int:
    """CRC-16 CCITT (poly 0x8408, init 0xFFFF, final XOR 0xFFFF)."""
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0x8408
            else:
                crc >>= 1
    return crc ^ 0xFFFF


# --- HDLC ---

def bit_stuff(bits: list) -> list:
    """Insert a 0 after every 5 consecutive 1-bits."""
    out = []
    ones = 0
    for b in bits:
        out.append(b)
        if b == 1:
            ones += 1
            if ones == 5:
                out.append(0)
                ones = 0
        else:
            ones = 0
    return out


def bytes_to_bits_lsb(data: bytes) -> list:
    """Convert bytes to list of bits, LSB first per byte."""
    bits = []
    for byte in data:
        for i in range(8):
            bits.append((byte >> i) & 1)
    return bits


def hdlc_frame(data: bytes, num_preamble: int = 50, num_tail: int = 5) -> list:
    """Wrap data in HDLC flags with bit stuffing. Returns bit stream."""
    flag_bits = [0, 1, 1, 1, 1, 1, 1, 0]

    fcs = ax25_fcs(data)
    fcs_bytes = struct.pack('<H', fcs)
    frame_with_fcs = data + fcs_bytes

    frame_bits = bytes_to_bits_lsb(frame_with_fcs)
    stuffed = bit_stuff(frame_bits)

    out = []
    for _ in range(num_preamble):
        out.extend(flag_bits)
    out.extend(stuffed)
    for _ in range(num_tail):
        out.extend(flag_bits)
    return out


# --- NRZI ---

def nrzi_encode(bits: list) -> list:
    """NRZI encode: 0 = transition, 1 = no transition."""
    state = 0  # start low
    out = []
    for b in bits:
        if b == 0:
            state ^= 1
        out.append(state)
    return out


# --- AFSK modulation ---

def afsk_modulate(nrzi_bits: list, sample_rate: int = 48000, baud: int = 1200,
                  mark_hz: float = 1200.0, space_hz: float = 2200.0) -> np.ndarray:
    """Generate AFSK audio from NRZI bit stream."""
    samples_per_bit = sample_rate / baud
    total_samples = int(len(nrzi_bits) * samples_per_bit)
    t = np.arange(total_samples) / sample_rate

    # Generate instantaneous frequency
    freq = np.zeros(total_samples)
    for i, bit in enumerate(nrzi_bits):
        start = int(i * samples_per_bit)
        end = int((i + 1) * samples_per_bit)
        if end > total_samples:
            end = total_samples
        freq[start:end] = mark_hz if bit == 0 else space_hz

    # Phase-continuous oscillator
    phase = np.cumsum(2 * np.pi * freq / sample_rate)
    audio = np.sin(phase)
    return audio


# --- FM modulation to IQ ---

def fm_modulate_iq(audio: np.ndarray, audio_rate: int = 48000,
                   iq_rate: int = 2048000, deviation: float = 3000.0) -> np.ndarray:
    """FM modulate audio to baseband IQ at iq_rate."""
    # Resample audio to IQ rate
    from scipy.signal import resample_poly
    from math import gcd
    g = gcd(iq_rate, audio_rate)
    up = iq_rate // g
    down = audio_rate // g
    resampled = resample_poly(audio, up, down)

    # FM: phase = integral of frequency deviation
    phase = np.cumsum(2 * np.pi * deviation * resampled / iq_rate)
    iq = np.exp(1j * phase)
    return iq


def iq_to_int8(iq: np.ndarray) -> bytes:
    """Convert complex IQ to interleaved int8 (I, Q, I, Q, ...)."""
    i_samples = np.clip(iq.real * 127, -127, 127).astype(np.int8)
    q_samples = np.clip(iq.imag * 127, -127, 127).astype(np.int8)
    interleaved = np.empty(len(i_samples) * 2, dtype=np.int8)
    interleaved[0::2] = i_samples
    interleaved[1::2] = q_samples
    return interleaved.tobytes()


# --- Main ---

def build_aprs_packet(dest: str, src: str, path: list, message: str) -> bytes:
    """Build a complete APRS position/message packet."""
    # Simple APRS message format: >status text
    info = f">{message}".encode('ascii')
    return ax25_build_ui_frame(dest, src, path, info)


def main():
    parser = argparse.ArgumentParser(description='APRS TX via HackRF')
    parser.add_argument('--dest', default='X3XU3F', help='Destination callsign')
    parser.add_argument('--src', default='HCKRF0', help='Source callsign')
    parser.add_argument('--path', default='WIDE1-1', help='Digipeater path (comma-separated)')
    parser.add_argument('--message', default='HackRF test 1', help='Message text')
    parser.add_argument('--freq', type=int, default=144800000, help='TX frequency in Hz')
    parser.add_argument('--gain', type=int, default=20, help='HackRF TX gain (0-47)')
    parser.add_argument('--wav', help='Output WAV file (for Direwolf validation)')
    parser.add_argument('--iq', help='Output IQ file instead of transmitting')
    parser.add_argument('--no-tx', action='store_true', help='Do not transmit via HackRF')
    args = parser.parse_args()

    path = [p.strip() for p in args.path.split(',') if p.strip()] if args.path else []

    # Build packet
    frame_data = build_aprs_packet(args.dest, args.src, path, args.message)
    print(f"AX.25 frame: {frame_data.hex()}")
    print(f"FCS: 0x{ax25_fcs(frame_data):04X}")

    # HDLC + NRZI
    hdlc_bits = hdlc_frame(frame_data)
    nrzi_bits = nrzi_encode(hdlc_bits)
    print(f"HDLC bits: {len(hdlc_bits)}, NRZI bits: {len(nrzi_bits)}")

    # AFSK modulation
    audio = afsk_modulate(nrzi_bits)
    print(f"Audio samples: {len(audio)} ({len(audio)/48000:.3f}s)")

    # Output WAV (for Direwolf cross-validation)
    if args.wav:
        import wave
        audio_int16 = (audio * 32767 * 0.8).astype(np.int16)
        with wave.open(args.wav, 'w') as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(48000)
            wf.writeframes(audio_int16.tobytes())
        print(f"WAV written: {args.wav}")

    # FM modulate to IQ
    iq = fm_modulate_iq(audio)
    iq_data = iq_to_int8(iq)
    print(f"IQ samples: {len(iq)}, IQ bytes: {len(iq_data)}")

    if args.iq:
        with open(args.iq, 'wb') as f:
            f.write(iq_data)
        print(f"IQ written: {args.iq}")

    if not args.no_tx and not args.iq:
        # Write IQ to temp file and transmit
        with tempfile.NamedTemporaryFile(suffix='.iq8', delete=False) as f:
            f.write(iq_data)
            iq_path = f.name
        cmd = [
            'hackrf_transfer',
            '-t', iq_path,
            '-f', str(args.freq),
            '-s', '2048000',
            '-x', str(args.gain),
        ]
        print(f"Transmitting: {' '.join(cmd)}")
        subprocess.run(cmd)
    elif args.no_tx:
        print("Skipping HackRF TX (--no-tx)")


if __name__ == '__main__':
    main()
