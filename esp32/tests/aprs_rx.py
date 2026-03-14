#!/usr/bin/env python3
"""
APRS RX via HackRF One — capture and decode APRS packets from 144.800 MHz.

Can also decode from WAV files (Direwolf-compatible audio).

Usage:
  python3 aprs_rx.py --capture 10              # Capture 10s from HackRF, decode
  python3 aprs_rx.py --iq capture.iq8          # Decode existing IQ file
  python3 aprs_rx.py --wav audio.wav           # Decode WAV file (like Direwolf)
"""

import argparse
import struct
import subprocess
import sys
import tempfile

import numpy as np


# --- FM demodulation ---

def fm_demod_iq(iq_data: bytes, iq_rate: int = 2048000, audio_rate: int = 48000) -> np.ndarray:
    """FM demodulate int8 IQ to audio."""
    from scipy.signal import resample_poly, butter, lfilter
    from math import gcd

    raw = np.frombuffer(iq_data, dtype=np.int8).astype(np.float32)
    i_samples = raw[0::2]
    q_samples = raw[1::2]
    iq = i_samples + 1j * q_samples

    phase_diff = np.angle(iq[1:] * np.conj(iq[:-1]))

    cutoff = audio_rate / 2
    nyq = iq_rate / 2
    b, a = butter(5, cutoff / nyq, btype='low')
    filtered = lfilter(b, a, phase_diff)

    g = gcd(iq_rate, audio_rate)
    up = audio_rate // g
    down = iq_rate // g
    audio = resample_poly(filtered, up, down)
    return audio


# --- AFSK demodulation using correlation (Direwolf-style) ---

def afsk_demod_correlator(audio: np.ndarray, sample_rate: int = 48000,
                          baud: int = 1200, mark_hz: float = 1200.0,
                          space_hz: float = 2200.0) -> np.ndarray:
    """
    Correlation-based AFSK demodulator.
    Correlate with one cycle of mark and space tones, compare energy.
    """
    # Generate one-cycle correlation templates
    mark_period = int(round(sample_rate / mark_hz))
    space_period = int(round(sample_rate / space_hz))

    t_mark = np.arange(mark_period) / sample_rate
    mark_cos = np.cos(2 * np.pi * mark_hz * t_mark)
    mark_sin = np.sin(2 * np.pi * mark_hz * t_mark)

    t_space = np.arange(space_period) / sample_rate
    space_cos = np.cos(2 * np.pi * space_hz * t_space)
    space_sin = np.sin(2 * np.pi * space_hz * t_space)

    n = len(audio)
    soft = np.zeros(n)

    for i in range(n):
        # Mark correlation
        end_m = min(i + mark_period, n)
        seg_m = audio[i:end_m]
        if len(seg_m) < mark_period:
            mc = mark_cos[:len(seg_m)]
            ms = mark_sin[:len(seg_m)]
        else:
            mc = mark_cos
            ms = mark_sin
        mark_energy = np.dot(seg_m, mc)**2 + np.dot(seg_m, ms)**2

        # Space correlation
        end_s = min(i + space_period, n)
        seg_s = audio[i:end_s]
        if len(seg_s) < space_period:
            sc = space_cos[:len(seg_s)]
            ss = space_sin[:len(seg_s)]
        else:
            sc = space_cos
            ss = space_sin
        space_energy = np.dot(seg_s, sc)**2 + np.dot(seg_s, ss)**2

        soft[i] = mark_energy - space_energy

    return soft


def afsk_demod_fast(audio: np.ndarray, sample_rate: int = 48000,
                    baud: int = 1200, mark_hz: float = 1200.0,
                    space_hz: float = 2200.0) -> np.ndarray:
    """Fast AFSK demod using delay-multiply, matching ESP32 approach."""
    from scipy.signal import butter, lfilter

    delay = int(round(sample_rate / baud / 2))
    delayed = np.zeros_like(audio)
    delayed[delay:] = audio[:-delay]
    mixed = audio * delayed

    cutoff = baud * 0.6
    nyq = sample_rate / 2
    b, a = butter(3, cutoff / nyq, btype='low')
    filtered = lfilter(b, a, mixed)
    return filtered


# --- Bit recovery with simple DLL ---

def recover_bits_dll(soft: np.ndarray, sample_rate: int = 48000, baud: int = 1200) -> list:
    """
    Digital locked loop bit recovery.
    Sample at mid-bit, adjust clock on zero-crossings.
    """
    spb = sample_rate / baud
    bits = []
    t = spb / 2  # Start sampling at mid-bit

    while t < len(soft) - 1:
        idx = int(t)
        bits.append(1 if soft[idx] > 0 else 0)

        # Look for zero crossing in next bit period for clock adjustment
        next_t = t + spb
        search_start = max(0, int(t + spb * 0.3))
        search_end = min(len(soft) - 1, int(t + spb * 0.7))

        best_cross = -1
        for j in range(search_start, search_end):
            if (soft[j] > 0) != (soft[j + 1] > 0):
                best_cross = j
                break

        if best_cross >= 0:
            # Transition found — adjust so next sample is spb/2 after it
            ideal = best_cross + spb / 2
            error = ideal - next_t
            next_t += error * 0.5  # Moderate correction

        t = next_t

    return bits


# --- NRZI decode ---

def nrzi_decode(bits: list) -> list:
    """NRZI decode: same level = 1, transition = 0."""
    out = []
    prev = bits[0] if bits else 0
    for b in bits[1:]:
        if b == prev:
            out.append(1)
        else:
            out.append(0)
        prev = b
    return out


# --- HDLC parse ---

def find_hdlc_frames(bits: list) -> list:
    """Find HDLC frames between 0x7E flags. Skips preamble flag runs."""
    flag = [0, 1, 1, 1, 1, 1, 1, 0]
    frames = []
    n = len(bits)
    i = 0
    while i <= n - 8:
        if bits[i:i+8] == flag:
            # Skip consecutive flags (preamble)
            while i + 8 <= n - 8 and bits[i+8:i+16] == flag:
                i += 8
            # Now i points to the last flag before data
            j = i + 8
            frame_bits = []
            while j <= n - 8:
                if bits[j:j+8] == flag:
                    if len(frame_bits) >= 16:
                        unstuffed = remove_bit_stuffing(frame_bits)
                        if unstuffed is not None and len(unstuffed) >= 16 and len(unstuffed) % 8 == 0:
                            frame_bytes = bits_to_bytes_lsb(unstuffed)
                            frames.append(frame_bytes)
                    i = j
                    break
                frame_bits.append(bits[j])
                j += 1
            else:
                break
        i += 1
    return frames


def remove_bit_stuffing(bits: list) -> list:
    """Remove stuffed zeros after 5 consecutive ones."""
    out = []
    ones = 0
    i = 0
    while i < len(bits):
        if ones == 5:
            if i < len(bits) and bits[i] == 0:
                ones = 0
                i += 1
                continue
            elif i < len(bits) and bits[i] == 1:
                return None
        out.append(bits[i])
        if bits[i] == 1:
            ones += 1
        else:
            ones = 0
        i += 1
    return out


def bits_to_bytes_lsb(bits: list) -> bytes:
    """Convert bit list to bytes, LSB first."""
    out = bytearray()
    for i in range(0, len(bits), 8):
        if i + 8 > len(bits):
            break
        byte = 0
        for j in range(8):
            byte |= bits[i + j] << j
        out.append(byte)
    return bytes(out)


# --- AX.25 decode ---

def ax25_check_fcs(frame: bytes) -> bool:
    """Verify AX.25 FCS."""
    if len(frame) < 17:
        return False
    data = frame[:-2]
    fcs_received = struct.unpack('<H', frame[-2:])[0]
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0x8408
            else:
                crc >>= 1
    crc ^= 0xFFFF
    return crc == fcs_received


def ax25_decode_address(data: bytes) -> str:
    """Decode 7-byte AX.25 address."""
    call = ''.join(chr(b >> 1) for b in data[:6]).strip()
    ssid = (data[6] >> 1) & 0x0F
    if ssid:
        return f"{call}-{ssid}"
    return call


def ax25_decode_frame(frame: bytes) -> dict:
    """Decode an AX.25 UI frame."""
    if not ax25_check_fcs(frame):
        return None
    data = frame[:-2]
    if len(data) < 16:
        return None
    dest = ax25_decode_address(data[0:7])
    src = ax25_decode_address(data[7:14])
    path = []
    i = 14
    if not (data[13] & 0x01):
        while i + 7 <= len(data):
            relay = ax25_decode_address(data[i:i+7])
            path.append(relay)
            if data[i + 6] & 0x01:
                i += 7
                break
            i += 7
    if i >= len(data):
        return None
    control = data[i]; i += 1
    pid = data[i] if i < len(data) else 0; i += 1
    info = data[i:] if i < len(data) else b''
    return {
        'dest': dest, 'src': src, 'path': path,
        'control': control, 'pid': pid,
        'info': info.decode('ascii', errors='replace'),
    }


# --- Decode pipeline ---

def decode_aprs_from_audio(audio: np.ndarray, sample_rate: int = 48000,
                           verbose: bool = False) -> list:
    """Full decode pipeline from audio to APRS packets."""
    packets = []

    # Try both demodulators
    for demod_name, demod_fn in [('fast', afsk_demod_fast)]:
        soft = demod_fn(audio, sample_rate)
        bits = recover_bits_dll(soft, sample_rate)
        if verbose:
            print(f"  [{demod_name}] Recovered {len(bits)} bits")
        nrzi = nrzi_decode(bits)
        frames = find_hdlc_frames(nrzi)
        if verbose:
            print(f"  [{demod_name}] Found {len(frames)} candidate frames")
        for frame in frames:
            fcs_ok = ax25_check_fcs(frame)
            if verbose:
                print(f"  [{demod_name}] Frame {len(frame)} bytes, FCS={'OK' if fcs_ok else 'FAIL'}")
            if fcs_ok:
                decoded = ax25_decode_frame(frame)
                if decoded:
                    packets.append(decoded)

    # Also try inverted polarity
    if not packets:
        soft = afsk_demod_fast(-audio, sample_rate)
        bits = recover_bits_dll(soft, sample_rate)
        nrzi = nrzi_decode(bits)
        frames = find_hdlc_frames(nrzi)
        for frame in frames:
            if ax25_check_fcs(frame):
                decoded = ax25_decode_frame(frame)
                if decoded:
                    packets.append(decoded)

    return packets


# --- Main ---

def main():
    parser = argparse.ArgumentParser(description='APRS RX via HackRF')
    parser.add_argument('--capture', type=float, help='Capture duration in seconds')
    parser.add_argument('--iq', help='Input IQ file to decode')
    parser.add_argument('--wav', help='Input WAV file to decode')
    parser.add_argument('--freq', type=int, default=144800000, help='RX frequency in Hz')
    parser.add_argument('--lna', type=int, default=32, help='HackRF LNA gain')
    parser.add_argument('--vga', type=int, default=20, help='HackRF VGA gain')
    parser.add_argument('-v', '--verbose', action='store_true', help='Verbose output')
    args = parser.parse_args()

    if args.wav:
        import wave
        with wave.open(args.wav, 'r') as wf:
            sr = wf.getframerate()
            n = wf.getnframes()
            raw = wf.readframes(n)
            if wf.getsampwidth() == 2:
                audio = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
            else:
                audio = np.frombuffer(raw, dtype=np.uint8).astype(np.float32) / 128.0 - 1.0
        print(f"Loaded WAV: {sr} Hz, {len(audio)} samples ({len(audio)/sr:.1f}s)")
        packets = decode_aprs_from_audio(audio, sr, args.verbose)

    elif args.iq:
        with open(args.iq, 'rb') as f:
            iq_data = f.read()
        print(f"Loaded IQ: {len(iq_data)} bytes ({len(iq_data)/2/2048000:.1f}s)")
        audio = fm_demod_iq(iq_data)
        packets = decode_aprs_from_audio(audio, verbose=args.verbose)

    elif args.capture:
        num_samples = int(args.capture * 2048000)
        with tempfile.NamedTemporaryFile(suffix='.iq8', delete=False) as f:
            iq_path = f.name
        cmd = [
            'hackrf_transfer', '-r', iq_path,
            '-f', str(args.freq), '-s', '2048000',
            '-l', str(args.lna), '-g', str(args.vga),
            '-n', str(num_samples),
        ]
        print(f"Capturing: {' '.join(cmd)}")
        subprocess.run(cmd)
        with open(iq_path, 'rb') as f:
            iq_data = f.read()
        print(f"Captured {len(iq_data)} bytes")
        if len(iq_data) > 0:
            audio = fm_demod_iq(iq_data)
            packets = decode_aprs_from_audio(audio, verbose=args.verbose)
        else:
            packets = []
    else:
        parser.print_help()
        sys.exit(1)

    if packets:
        print(f"\n=== Decoded {len(packets)} APRS packet(s) ===")
        for i, pkt in enumerate(packets):
            path_str = ','.join(pkt['path']) if pkt['path'] else ''
            print(f"[{i+1}] {pkt['src']}>{pkt['dest']}"
                  f"{(',' + path_str) if path_str else ''}"
                  f":{pkt['info']}")
    else:
        print("\nNo APRS packets decoded.")


if __name__ == '__main__':
    main()
