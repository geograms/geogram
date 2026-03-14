#!/usr/bin/env python3
"""
AFSK demodulator test suite — exact Python replica of the ESP32 C demodulator
in esp32/components/geogram_sa818/sa818_radio.c.

Tests:
  1. Synthetically generated AFSK signal at 9600 Hz (clean, centered)
  2. Direwolf-generated WAV (if present at direwolf_ref.wav), resampled to 9600 Hz
  3. Signal from aprs_tx.py encoder, downsampled 48000→9600 Hz
  4. ADC simulation: 12-bit quantisation + DC offset + hard clipping at 0
  5. Edge cases: min-length frame, multi-hop path, flags-only
  6. CRC validation: corrupted frames rejected, valid frames accepted
  7. FIR coefficient sanity check
  8. Demodulator parameter sanity check

Run:
  python3 demod_test.py
  python3 demod_test.py --verbose
  python3 demod_test.py --wav /path/to/file.wav   # override WAV path

Signal-level notes:
  - The delay-multiply discriminator product  s[n]*s[n-4] must fit in int16 after >> 7.
    Maximum safe amplitude = floor(sqrt(32767 * 128)) = 2047 counts.
  - For clean synthetic tests, samples are generated centred at 0 and fed directly
    to the inner demodulator (feed_sample), skipping the outer ADC DC-removal stage.
  - For ADC simulation tests, samples are generated with a 2048-count DC offset and
    fed through the full process_adc_samples() pipeline which includes that stage.
  - The FIR filter has group delay of 15 samples (~2 bit periods), so the demodulated
    bit stream is delayed by 2 bits relative to the modulated signal.  This is
    transparent to the HDLC layer because it just sees a continuous bit stream.
"""

import argparse
import math
import os
import struct
import sys
import wave

import numpy as np

# ---------------------------------------------------------------------------
# Constants — mirror sa818_radio.c exactly
# ---------------------------------------------------------------------------
APRS_SAMPLE_RATE_HZ   = 9600
APRS_BITRATE_BPS      = 1200
APRS_MARK_FREQ_HZ     = 1200.0
APRS_SPACE_FREQ_HZ    = 2200.0
APRS_SAMPLES_PER_BIT  = APRS_SAMPLE_RATE_HZ // APRS_BITRATE_BPS   # 8
APRS_DEMOD_DELAY      = (APRS_SAMPLE_RATE_HZ + APRS_BITRATE_BPS) // (2 * APRS_BITRATE_BPS)  # 4
APRS_FIR_TAPS         = 31
APRS_PHASE_BITS       = 8
APRS_PHASE_INC        = 2
APRS_PHASE_MAX        = (APRS_SAMPLE_RATE_HZ // APRS_BITRATE_BPS) * APRS_PHASE_BITS  # 64
APRS_PHASE_THRESHOLD  = APRS_PHASE_MAX // 2                         # 32

APRS_HDLC_FLAG        = 0x7E
APRS_HDLC_RESET       = 0x7F
APRS_AX25_ESC         = 0x1B
APRS_AX25_CRC_CORRECT = 0xF0B8
APRS_MAX_FRAME_BYTES  = 330
APRS_MAX_INFO_BYTES   = 120
APRS_RX_FIFO_SIZE     = 768

# Maximum safe sample amplitude for the delay-multiply discriminator.
# product = s[n]*s[n-4]; (product >> 7) must fit in int16.
# amp^2 / 128 <= 32767  →  amp <= floor(sqrt(32767*128)) = 2047
DEMOD_MAX_AMP = 2047

# ---------------------------------------------------------------------------
# CRC-16 CCITT (poly 0x8408, init 0xFFFF) — matches aprs_crc16_update()
# ---------------------------------------------------------------------------

def crc16_update(crc: int, byte: int) -> int:
    crc ^= byte & 0xFF
    for _ in range(8):
        if crc & 0x0001:
            crc = ((crc >> 1) ^ 0x8408) & 0xFFFF
        else:
            crc >>= 1
    return crc & 0xFFFF


def crc16(data: bytes) -> int:
    """CRC-16/X25: init=0xFFFF, poly=0x8408, final-XOR=0xFFFF."""
    crc = 0xFFFF
    for b in data:
        crc = crc16_update(crc, b)
    return (~crc) & 0xFFFF


# ---------------------------------------------------------------------------
# FIR low-pass filter design — exact replica of aprs_design_fir_bandpass()
#
# The C code calls: aprs_design_fir_bandpass(coeff, pass_hz=0.0, cutoff_hz=1200.0)
# Window used: aprs_windowf(x) = 0.54 + 0.46*cos(x)  → Hamming window
# Note: despite the Blackman-Harris description in some comments, the C source
# uses the two-term Hamming form.
# ---------------------------------------------------------------------------

def _sinc(x: float) -> float:
    if abs(x) < 1e-6:
        return 1.0
    return math.sin(x) / x


def _hamming_window(x: float) -> float:
    """aprs_windowf(x) = 0.54 + 0.46*cos(x)"""
    return 0.54 + 0.46 * math.cos(x)


def design_fir_lowpass() -> list:
    """
    Matches aprs_design_fir_bandpass(coeffs, pass_hz=0.0, cutoff_hz=1200.0).

    coeff[n+mid] = 32767 * 2 * (rc*sinc(2π*rc*n) - rp*sinc(2π*rp*n))
                   * window(π*n/mid)
    where rp = 0/9600 = 0, rc = 1200/9600 = 0.125
    """
    taps = APRS_FIR_TAPS
    mid  = (taps - 1) // 2  # 15
    rp   = 0.0 / APRS_SAMPLE_RATE_HZ          # 0.0
    rc   = 1200.0 / APRS_SAMPLE_RATE_HZ        # 0.125
    amplitude = 32767.0

    coeffs = [0] * taps
    for n in range(-mid, mid + 1):
        coeff = amplitude * 2.0 * (
            rc * _sinc(2.0 * math.pi * rc * n)
            - rp * _sinc(2.0 * math.pi * rp * n)
        ) * _hamming_window(math.pi * n / mid if mid != 0 else 0.0)
        coeffs[n + mid] = int(round(coeff))
    return coeffs


# Cache the FIR coefficients (they never change)
_FIR_COEFFICIENTS = design_fir_lowpass()


# ---------------------------------------------------------------------------
# Decoder state — Python mirror of aprs_decoder_state_t
# ---------------------------------------------------------------------------

class DecoderState:
    def __init__(self):
        self.lpf_hist  = [0] * APRS_FIR_TAPS
        self.lpf_index = 0

        self.delay_line = [0] * APRS_DEMOD_DELAY
        self.delay_idx  = 0

        self.discriminator_dc_q8 = 0

        self.sampled_bits = 0   # uint16_t
        self.actual_bits  = 0   # uint8_t
        self.current_phase = 0  # int16_t

        # HDLC
        self.hdlc_demod_bits   = 0   # uint8_t (bit stream window)
        self.hdlc_bit_index    = 0
        self.hdlc_current_byte = 0
        self.hdlc_receiving    = False

        # AX.25
        self.rx_fifo: list = []
        self.ax25_sync       = False
        self.ax25_escape     = False
        self.ax25_crc_in     = 0xFFFF
        self.ax25_frame      = bytearray()
        self.ax25_frame_len  = 0

        # Statistics
        self.nrzi_bits       = 0
        self.flag_seen       = 0
        self.frame_candidates = 0
        self.crc_ok          = 0
        self.crc_fail        = 0
        self.fifo_overflow   = 0

        # Decoded packets (list of raw frame bytes including FCS)
        self.packets: list = []


# ---------------------------------------------------------------------------
# Integer clamp helpers
# ---------------------------------------------------------------------------

def _clamp16(v: int) -> int:
    if v > 32767:
        return 32767
    if v < -32768:
        return -32768
    return int(v)


def _to_uint8(v: int) -> int:
    return v & 0xFF


# ---------------------------------------------------------------------------
# FIR filter — matches aprs_decoder_filter_core()
#
# Circular history buffer; newest sample written at hist[index].
# Sum: coeffs[i] * hist[(index+i) % TAPS]
# Advance: index = (index + TAPS - 1) % TAPS
# Return: int16(sum >> 16)
# ---------------------------------------------------------------------------

def fir_filter(state: DecoderState, sample: int) -> int:
    taps  = APRS_FIR_TAPS
    idx   = state.lpf_index
    state.lpf_hist[idx] = _clamp16(sample)

    total = 0
    for i in range(taps):
        h_idx = (idx + i) % taps
        total += _FIR_COEFFICIENTS[i] * state.lpf_hist[h_idx]

    state.lpf_index = (idx + taps - 1) % taps
    return _clamp16(total >> 16)


# ---------------------------------------------------------------------------
# aprs_signal_transitioned: ((bits ^ (bits>>2)) & 0x03) == 0x03
# True when bit[1] != bit[3] (transition two samples ago vs now).
# ---------------------------------------------------------------------------

def signal_transitioned(bits: int) -> bool:
    return ((bits ^ (bits >> 2)) & 0x03) == 0x03


# ---------------------------------------------------------------------------
# aprs_transition_found: ((bits ^ (bits>>1)) & 0x01) != 0
# Compares current bit (LSB) vs previous bit (bit 1).
# ---------------------------------------------------------------------------

def transition_found(bits: int) -> bool:
    return ((bits ^ (bits >> 1)) & 0x01) != 0


# ---------------------------------------------------------------------------
# count_ones_u8 — popcount of a byte
# ---------------------------------------------------------------------------

def count_ones_u8(v: int) -> int:
    v &= 0xFF
    count = 0
    while v:
        v &= v - 1
        count += 1
    return count


# ---------------------------------------------------------------------------
# FIFO helpers
# ---------------------------------------------------------------------------

def fifo_push(state: DecoderState, c: int) -> bool:
    if len(state.rx_fifo) >= APRS_RX_FIFO_SIZE:
        state.fifo_overflow += 1
        return False
    state.rx_fifo.append(c & 0xFF)
    return True


def fifo_flush(state: DecoderState):
    state.rx_fifo.clear()


# ---------------------------------------------------------------------------
# aprs_decoder_poll_ax25 — drain FIFO and assemble AX.25 frame buffer.
#
# Frame bytes are accumulated including the 2-byte FCS.  The incremental CRC
# (ax25_crc_in) covers all accumulated bytes; a valid frame leaves residue
# 0xF0B8 (CCITT).
# ---------------------------------------------------------------------------

def poll_ax25(state: DecoderState):
    while state.rx_fifo:
        c = state.rx_fifo.pop(0)

        if not state.ax25_escape and c == APRS_HDLC_FLAG:
            if state.ax25_frame_len >= 18:
                state.frame_candidates += 1
                if state.ax25_crc_in == APRS_AX25_CRC_CORRECT:
                    frame_bytes = bytes(state.ax25_frame[:state.ax25_frame_len])
                    state.packets.append(frame_bytes)
                    state.crc_ok += 1
                else:
                    state.crc_fail += 1
            state.ax25_sync      = True
            state.ax25_crc_in    = 0xFFFF
            state.ax25_frame     = bytearray()
            state.ax25_frame_len = 0
            continue

        if not state.ax25_escape and c == APRS_HDLC_RESET:
            state.ax25_sync      = False
            state.ax25_frame_len = 0
            continue

        if not state.ax25_escape and c == APRS_AX25_ESC:
            state.ax25_escape = True
            continue

        if state.ax25_sync:
            if state.ax25_frame_len < APRS_MAX_FRAME_BYTES:
                if len(state.ax25_frame) <= state.ax25_frame_len:
                    state.ax25_frame.append(c)
                else:
                    state.ax25_frame[state.ax25_frame_len] = c
                state.ax25_frame_len += 1
                state.ax25_crc_in = crc16_update(state.ax25_crc_in, c)
            else:
                state.ax25_sync      = False
                state.ax25_frame_len = 0

        state.ax25_escape = False


# ---------------------------------------------------------------------------
# aprs_decoder_hdlc_parse — HDLC bit stream decoder.
#
# hdlc_demod_bits is a shift register (uint8, newest bit at LSB).
# Bit stuffing: if lower 6 bits = 0x3E, drop this bit (stuff bit removal).
# Flag = 0x7E detects start/end; Reset = 0x7F (or 7+ ones) aborts.
# Byte assembly: incoming bit enters at MSB (|= 0x80) then shifts right.
# ---------------------------------------------------------------------------

def hdlc_parse(state: DecoderState, bit: bool) -> bool:
    ret = True

    state.hdlc_demod_bits = _to_uint8(
        (state.hdlc_demod_bits << 1) | (1 if bit else 0)
    )

    if state.hdlc_demod_bits == APRS_HDLC_FLAG:
        if not fifo_push(state, APRS_HDLC_FLAG):
            ret = False
            state.hdlc_receiving = False
        else:
            state.hdlc_receiving = True
            state.flag_seen += 1
        state.hdlc_current_byte = 0
        state.hdlc_bit_index    = 0
        return ret

    if (state.hdlc_demod_bits & APRS_HDLC_RESET) == APRS_HDLC_RESET:
        state.hdlc_receiving = False
        return ret

    if not state.hdlc_receiving:
        return ret

    # Bit-stuffing removal: 5 consecutive 1s followed by a 0 → drop the 0
    if (state.hdlc_demod_bits & 0x3F) == 0x3E:
        return ret

    # Assemble byte: bit enters at MSB, then shifts right for the next bit
    if state.hdlc_demod_bits & 0x01:
        state.hdlc_current_byte |= 0x80

    state.hdlc_bit_index += 1
    if state.hdlc_bit_index >= 8:
        byte_val = state.hdlc_current_byte & 0xFF
        # Escape reserved bytes so poll_ax25 can distinguish them from
        # in-band control bytes.
        if byte_val in (APRS_HDLC_FLAG, APRS_HDLC_RESET, APRS_AX25_ESC):
            if not fifo_push(state, APRS_AX25_ESC):
                state.hdlc_receiving = False
                ret = False

        if not fifo_push(state, byte_val):
            state.hdlc_receiving = False
            ret = False

        state.hdlc_current_byte = 0
        state.hdlc_bit_index    = 0
    else:
        state.hdlc_current_byte = _to_uint8(state.hdlc_current_byte >> 1)

    return ret


# ---------------------------------------------------------------------------
# aprs_decoder_process_nrzi_bit
# ---------------------------------------------------------------------------

def process_nrzi_bit(state: DecoderState, bit: int):
    state.nrzi_bits += 1
    if not hdlc_parse(state, bit != 0):
        fifo_flush(state)
        state.ax25_sync      = False
        state.ax25_escape    = False
        state.ax25_crc_in    = 0xFFFF
        state.ax25_frame_len = 0
    poll_ax25(state)


# ---------------------------------------------------------------------------
# aprs_decoder_feed_sample — core demodulator step.
#
# Implements the full pipeline:
#   1. Delay-multiply FM discriminator  (delay = 4 samples)
#   2. FIR low-pass filter              (31 taps, Hamming, Fc=1200 Hz)
#   3. Inner DC removal                 (IIR, alpha=1/64)
#   4. Binarise → shift into sampled_bits
#   5. PLL phase accumulator            (PHASE_BITS=8, MAX=64, INC=2)
#   6. 5-bit majority vote              → actual bit value
#   7. NRZI decode                      → raw data bit
#   8. HDLC + AX.25 parse
#
# IMPORTANT: sample amplitude must stay below DEMOD_MAX_AMP (2047) to prevent
# the delay-multiply product from overflowing int16 after the >> 7 shift.
# ---------------------------------------------------------------------------

def feed_sample(state: DecoderState, sample: int):
    # 1. Delay line: read oldest, store newest
    delayed = state.delay_line[state.delay_idx]
    state.delay_line[state.delay_idx] = _clamp16(sample)
    state.delay_idx = (state.delay_idx + 1) % APRS_DEMOD_DELAY

    # 2. Delay-multiply FM discriminator
    mixed = sample * delayed  # int32; max ≈ 2047^2 = 4,190,209 → fits in int32

    # 3. Scale to int16 range and apply FIR low-pass
    discriminator = fir_filter(state, _clamp16(mixed >> 7))

    # 4. Inner DC removal (IIR, shift-right-6 ≈ alpha=1/64, slow tracking)
    discriminator_q8 = discriminator << 8
    state.discriminator_dc_q8 += (discriminator_q8 - state.discriminator_dc_q8) >> 6
    discriminator_centered = _clamp16(discriminator - (state.discriminator_dc_q8 >> 8))

    # 5. Binarise and push into sampled_bits shift register (uint16)
    state.sampled_bits = (
        ((state.sampled_bits << 1) | (1 if discriminator_centered > 0 else 0))
        & 0xFFFF
    )

    # 6. PLL: if a transition is detected in the signal, adjust the phase
    #    to re-align the bit clock.
    if signal_transitioned(state.sampled_bits):
        if state.current_phase < APRS_PHASE_THRESHOLD:
            state.current_phase += APRS_PHASE_INC
        else:
            state.current_phase -= APRS_PHASE_INC

    state.current_phase += APRS_PHASE_BITS
    if state.current_phase < APRS_PHASE_MAX:
        return  # not yet time to sample a bit

    state.current_phase %= APRS_PHASE_MAX

    # 7. 5-bit majority vote on the last 5 binary samples
    state.actual_bits = _to_uint8(state.actual_bits << 1)
    bit_window = state.sampled_bits & 0x1F
    if count_ones_u8(bit_window) >= 3:
        state.actual_bits |= 1

    # 8. NRZI decode: no transition between consecutive actual_bits → data 1
    nrzi_bit = 0 if transition_found(state.actual_bits) else 1
    process_nrzi_bit(state, nrzi_bit)


# ---------------------------------------------------------------------------
# Outer ADC DC-removal stage — matches sa818_radio_rx_process_sample().
#
# The outer IIR uses alpha ≈ 1/128 (shift-right-7), optimised for removing a
# slow ADC bias (e.g., the 2048-count midpoint of a 12-bit unipolar ADC).
# After centering, the sample is fed to feed_sample().
#
# Use this for ADC-simulated inputs.  For clean synthetic signals already
# centred at 0, call feed_sample() directly to avoid introducing artefacts.
# ---------------------------------------------------------------------------

def process_adc_samples(state: DecoderState, raw_samples,
                        dc_estimate_q8: int = 0,
                        dc_initialized: bool = False):
    """
    Feed raw ADC samples (e.g., 0–4095 for 12-bit) through the outer
    DC-removal stage and into the demodulator.

    Returns updated (dc_estimate_q8, dc_initialized).
    """
    for raw in raw_samples:
        raw = int(raw)
        if not dc_initialized:
            dc_estimate_q8 = raw << 8
            dc_initialized = True
        raw_q8 = raw << 8
        dc_estimate_q8 += (raw_q8 - dc_estimate_q8) >> 7

        centered = raw - (dc_estimate_q8 >> 8)
        feed_sample(state, _clamp16(centered))

    return dc_estimate_q8, dc_initialized


# ===========================================================================
# AX.25 / HDLC encoding helpers (for test signal generation)
# ===========================================================================

def ax25_encode_address(callsign: str, ssid: int = 0, last: bool = False) -> bytes:
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
    """
    Build an AX.25 UI frame.  The 'last' (end-of-address-list) bit is set on
    the final address only — always src when path is empty, or the last
    path entry when path is non-empty.  Dest never gets the last bit.
    """
    frame = bytearray()
    frame += ax25_encode_address(dest, last=False)         # dest: never last
    if path:
        frame += ax25_encode_address(src, last=False)      # src: not last (path follows)
        for i, relay in enumerate(path):
            parts = relay.split('-')
            call = parts[0]
            ssid = int(parts[1]) if len(parts) > 1 else 0
            frame += ax25_encode_address(call, ssid, last=(i == len(path) - 1))
    else:
        frame += ax25_encode_address(src, last=True)       # src: last (no path)
    frame += bytes([0x03, 0xF0])
    frame += info
    return bytes(frame)


def bit_stuff(bits: list) -> list:
    out, ones = [], 0
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
    bits = []
    for byte in data:
        for i in range(8):
            bits.append((byte >> i) & 1)
    return bits


def hdlc_frame_bits(data: bytes, num_preamble: int = 50, num_tail: int = 5) -> list:
    flag_bits = [0, 1, 1, 1, 1, 1, 1, 0]
    fcs = crc16(data)
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


def nrzi_encode(bits: list) -> list:
    """NRZI: data 0 = transition, data 1 = no transition. State starts at 0."""
    state = 0
    out = []
    for b in bits:
        if b == 0:
            state ^= 1
        out.append(state)
    return out


def afsk_modulate_9600(nrzi_bits: list,
                       sample_rate: int = APRS_SAMPLE_RATE_HZ,
                       baud: int = APRS_BITRATE_BPS,
                       mark_hz: float = APRS_MARK_FREQ_HZ,
                       space_hz: float = APRS_SPACE_FREQ_HZ) -> np.ndarray:
    """
    Phase-continuous AFSK modulator.
    NRZI state 0 → mark (1200 Hz), NRZI state 1 → space (2200 Hz).
    Returns float array normalised to ±1.
    """
    samples_per_bit = sample_rate / baud
    total = int(len(nrzi_bits) * samples_per_bit)
    freq = np.zeros(total)
    for i, bit in enumerate(nrzi_bits):
        s = int(i * samples_per_bit)
        e = min(int((i + 1) * samples_per_bit), total)
        freq[s:e] = mark_hz if bit == 0 else space_hz
    phase = np.cumsum(2 * np.pi * freq / sample_rate)
    return np.sin(phase)


def make_afsk_samples(dest: str, src: str, path: list, info: bytes,
                      amplitude: int = 1000,
                      num_preamble: int = 50, num_tail: int = 5) -> np.ndarray:
    """
    Build a complete AX.25+HDLC+NRZI+AFSK signal at 9600 Hz.
    amplitude must be <= DEMOD_MAX_AMP (2047) to avoid discriminator clipping.
    Returns int16 numpy array centred at 0.
    """
    assert amplitude <= DEMOD_MAX_AMP, \
        f"Amplitude {amplitude} exceeds DEMOD_MAX_AMP {DEMOD_MAX_AMP}"
    frame = ax25_build_ui_frame(dest, src, path, info)
    bits  = hdlc_frame_bits(frame, num_preamble=num_preamble, num_tail=num_tail)
    nrzi  = nrzi_encode(bits)
    audio = afsk_modulate_9600(nrzi)
    return (audio * amplitude).astype(np.int16)


# ---------------------------------------------------------------------------
# AX.25 frame parser — mirrors aprs_decode_ax25_frame()
# ---------------------------------------------------------------------------

def decode_ax25_address(addr_bytes: bytes) -> str:
    call = ''
    for b in addr_bytes[:6]:
        c = chr(b >> 1)
        if c != ' ':
            call += c
    ssid = (addr_bytes[6] >> 1) & 0x0F
    return f"{call}-{ssid}" if ssid else call


def parse_ax25_frame(frame: bytes):
    """
    Returns dict with src, dst, path, info on success, or None on failure.
    Frame bytes include the 2-byte FCS at the end.
    """
    if len(frame) < 18:
        return None

    # Verify FCS (the packets in state.packets still include the FCS bytes)
    fcs_received = frame[-2] | (frame[-1] << 8)
    fcs_computed  = crc16(frame[:-2])
    if fcs_computed != fcs_received:
        return None

    payload = frame[:-2]
    idx = 0
    addresses = []
    last = False
    while not last:
        if idx + 7 > len(payload) or len(addresses) >= 8:
            return None
        addresses.append(payload[idx:idx+7])
        last = bool(payload[idx+6] & 0x01)
        idx += 7

    if len(addresses) < 2 or idx + 2 > len(payload):
        return None

    control = payload[idx]; idx += 1
    pid     = payload[idx]; idx += 1
    if control != 0x03 or pid != 0xF0:
        return None

    dst  = decode_ax25_address(addresses[0])
    src  = decode_ax25_address(addresses[1])
    path = ','.join(decode_ax25_address(a) for a in addresses[2:])
    info = payload[idx:].decode('ascii', errors='replace')
    return {'src': src, 'dst': dst, 'path': path, 'info': info}


# ===========================================================================
# Test infrastructure
# ===========================================================================

PASS_STR = '\033[32mPASS\033[0m'
FAIL_STR = '\033[31mFAIL\033[0m'
SKIP_STR = '\033[33mSKIP\033[0m'


def run_test_inner(label: str, samples, expected_info_substr: str = None,
                   use_adc_pipeline: bool = False,
                   verbose: bool = False) -> bool:
    """
    Feed samples through the demod chain and check whether at least one
    valid AX.25 packet is decoded.

    samples: int-iterable of centred int16 values (use_adc_pipeline=False)
             OR raw ADC values 0-4095  (use_adc_pipeline=True)
    """
    state = DecoderState()

    if use_adc_pipeline:
        process_adc_samples(state, samples)
    else:
        for s in samples:
            feed_sample(state, int(s))

    decoded = []
    for frame in state.packets:
        p = parse_ax25_frame(frame)
        if p:
            decoded.append(p)

    ok = len(decoded) > 0
    if expected_info_substr and ok:
        ok = any(expected_info_substr in p['info'] for p in decoded)

    status = PASS_STR if ok else FAIL_STR
    print(f"  [{status}] {label}")
    if verbose or not ok:
        print(f"         nrzi_bits={state.nrzi_bits} flags={state.flag_seen} "
              f"candidates={state.frame_candidates} crc_ok={state.crc_ok} "
              f"crc_fail={state.crc_fail}")
        for p in decoded:
            print(f"         Decoded: {p['src']}>{p['dst']}"
                  f"{(','+p['path']) if p['path'] else ''}:{p['info']!r}")
        if not decoded:
            print("         No packets decoded")
    return ok


# ===========================================================================
# Test 1 — Clean synthetic AFSK at 9600 Hz
# ===========================================================================

def test_clean_synthetic(verbose: bool = False) -> bool:
    print("\nTest 1: Clean synthetic AFSK at 9600 Hz")
    results = []

    packets = [
        ('APRS', 'N0CALL', [],          b'>Hello APRS 1200 baud test'),
        ('APRS', 'W1AW',   ['WIDE1-1'], b':W1AW     :Test message{001'),
        ('APRS', 'KD9SDF', [],          b'!3745.00N/12223.00W-Test position'),
        ('APRS', 'VE3ABC', ['RELAY', 'WIDE'], b'>Status update packet'),
    ]

    all_samples = []
    for dest, src, path, info in packets:
        samples = make_afsk_samples(dest, src, path, info, amplitude=1000)
        all_samples.append(samples)
        label = f"{src}>{dest} {info[:30]!r}"
        ok = run_test_inner(label, samples.tolist(), verbose=verbose)
        results.append(ok)

    # All packets concatenated in one continuous stream
    combined = np.concatenate(all_samples)
    state = DecoderState()
    for s in combined:
        feed_sample(state, int(s))
    ok = state.crc_ok == len(packets)
    status = PASS_STR if ok else FAIL_STR
    print(f"  [{status}] All {len(packets)} packets back-to-back: "
          f"{state.crc_ok}/{len(packets)} decoded")
    results.append(ok)

    return all(results)


# ===========================================================================
# Test 2 — Direwolf-generated WAV (optional)
# ===========================================================================

def test_direwolf_wav(wav_path: str, verbose: bool = False) -> bool:
    print(f"\nTest 2: Direwolf WAV: {wav_path}")

    if not os.path.exists(wav_path):
        print(f"  [{SKIP_STR}] File not found — skipping")
        return True  # optional test

    try:
        from scipy.signal import resample_poly
        from math import gcd
    except ImportError:
        print(f"  [{SKIP_STR}] scipy not available — cannot resample")
        return True

    with wave.open(wav_path, 'r') as wf:
        n_channels = wf.getnchannels()
        sampwidth  = wf.getsampwidth()
        framerate  = wf.getframerate()
        n_frames   = wf.getnframes()
        raw        = wf.readframes(n_frames)

    if sampwidth == 2:
        samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32)
    elif sampwidth == 1:
        samples = (np.frombuffer(raw, dtype=np.uint8).astype(np.float32) - 128.0) * 256.0
    else:
        print(f"  [{SKIP_STR}] Unsupported sample width: {sampwidth}")
        return True

    if n_channels == 2:
        samples = (samples[0::2] + samples[1::2]) / 2

    print(f"  WAV: {framerate} Hz, {n_channels} ch, {sampwidth*8}-bit, "
          f"{len(samples)} samples")

    if framerate != APRS_SAMPLE_RATE_HZ:
        g = gcd(APRS_SAMPLE_RATE_HZ, framerate)
        samples = resample_poly(samples, APRS_SAMPLE_RATE_HZ // g, framerate // g)
        print(f"  Resampled → {APRS_SAMPLE_RATE_HZ} Hz: {len(samples)} samples")

    # Scale to safe amplitude for delay-multiply discriminator
    peak = np.max(np.abs(samples))
    if peak > 0:
        scale = min(1.0, DEMOD_MAX_AMP / peak)
        samples = samples * scale

    samples_int = np.clip(np.round(samples), -32768, 32767).astype(np.int16)

    state = DecoderState()
    for s in samples_int:
        feed_sample(state, int(s))

    ok = state.crc_ok > 0
    status = PASS_STR if ok else FAIL_STR
    print(f"  [{status}] {state.crc_ok} packet(s) decoded "
          f"(flags={state.flag_seen} candidates={state.frame_candidates} "
          f"crc_fail={state.crc_fail})")
    if verbose:
        for frame in state.packets:
            p = parse_ax25_frame(frame)
            if p:
                print(f"         {p['src']}>{p['dst']}:{p['info']!r}")
    return ok


# ===========================================================================
# Test 3 — aprs_tx.py encoder at 48 kHz, downsampled to 9600 Hz
# ===========================================================================

def test_aprs_tx_encoder(verbose: bool = False) -> bool:
    print("\nTest 3: aprs_tx.py encoder (48 kHz) → downsample to 9600 Hz")

    try:
        from scipy.signal import resample_poly
    except ImportError:
        print(f"  [{SKIP_STR}] scipy not available — cannot resample")
        return True

    results = []
    test_cases = [
        ('APRS', 'HACKRF', [],          b'>HackRF test 1'),
        ('APRS', 'N0CALL', ['WIDE1-1'], b':N0CALL   :Test message{001'),
        ('APRS', 'KA1ABC', [],          b'!4903.50N/07201.75W-PHG5132/Home'),
    ]

    for dest, src, path, info in test_cases:
        frame = ax25_build_ui_frame(dest, src, path, info)
        bits  = hdlc_frame_bits(frame, num_preamble=50, num_tail=5)
        nrzi  = nrzi_encode(bits)

        # Generate at 48000 Hz (matches aprs_tx.py)
        audio_48k = afsk_modulate_9600(nrzi, sample_rate=48000)
        # aprs_tx.py uses amplitude 0.8 * 32767 ≈ 26213 — too large for discriminator.
        # Scale to DEMOD_MAX_AMP before downsampling.
        audio_scaled = audio_48k * DEMOD_MAX_AMP  # float, peak ≈ DEMOD_MAX_AMP

        # Downsample 48000→9600 (exact factor 5)
        audio_9600 = resample_poly(audio_scaled, 1, 5)
        peak = np.max(np.abs(audio_9600))
        if peak > DEMOD_MAX_AMP:
            audio_9600 = audio_9600 * (DEMOD_MAX_AMP / peak)
        samples = np.clip(np.round(audio_9600), -32768, 32767).astype(np.int16)

        label = f"{src}>{dest} {info[:30]!r}"
        ok = run_test_inner(label, samples.tolist(), verbose=verbose)
        results.append(ok)

    return all(results)


# ===========================================================================
# Test 4 — ADC simulation: 12-bit, DC offset at 2048, clipping at 0
# ===========================================================================

def _make_adc_samples(dest: str, src: str, path: list, info: bytes,
                       amplitude: int, dc_offset: int = 2048,
                       silence_prefix_ms: int = 100) -> np.ndarray:
    """
    Build a 12-bit ADC sample stream.

    The outer DC-removal IIR (alpha≈1/128) needs ~500 samples to converge from
    the initial estimate to the true DC level.  Prepending silence (constant
    dc_offset) lets the DC estimate converge before the AFSK signal arrives,
    matching real-world SA818 behaviour where the ADC idles at mid-scale before
    the squelch opens.

    amplitude must be <= DEMOD_MAX_AMP (2047).
    """
    assert amplitude <= DEMOD_MAX_AMP
    frame  = ax25_build_ui_frame(dest, src, path, info)
    bits   = hdlc_frame_bits(frame, num_preamble=50, num_tail=5)
    nrzi   = nrzi_encode(bits)
    audio  = afsk_modulate_9600(nrzi)

    # Silence prefix: constant DC — allows the outer IIR to settle to dc_offset.
    silence_samples = int(silence_prefix_ms * APRS_SAMPLE_RATE_HZ / 1000)
    silence = np.full(silence_samples, float(dc_offset))

    adc_float = np.concatenate([silence, audio * amplitude + dc_offset])
    return np.clip(np.round(adc_float), 0, 4095).astype(np.int32)


def test_adc_conditions(verbose: bool = False) -> bool:
    print("\nTest 4: ADC simulation (12-bit, DC offset=2048, clipping at 0)")
    print("        (Silence prefix lets outer DC-IIR converge before signal)")

    results = []

    # --- Normal ADC conditions: 2048 DC + audio at 20% FS ---
    for dest, src, info in [
        ('APRS', 'N0CALL', b'>ADC sim test A'),
        ('APRS', 'W9XYZ',  b'>ADC sim test B'),
    ]:
        amplitude = 409  # 20% of 12-bit half-range (2047)
        adc_12bit = _make_adc_samples(dest, src, [], info, amplitude)
        label = f"12-bit ADC (ampl={amplitude}, 20% FS): {src}>{dest}"
        ok = run_test_inner(label, adc_12bit.tolist(),
                            use_adc_pipeline=True, verbose=verbose)
        results.append(ok)

    # --- Near-maximum safe amplitude: 2047 counts ---
    adc_12bit = _make_adc_samples('APRS', 'N0CALL', [], b'>ADC max-amplitude test',
                                   DEMOD_MAX_AMP)
    ok = run_test_inner("12-bit ADC max safe amplitude (2047 counts)",
                        adc_12bit.tolist(), use_adc_pipeline=True, verbose=verbose)
    results.append(ok)

    # --- Low signal level: 48 counts p-p (minimum reliable amplitude) ---
    # Minimum viable amplitude is ~48 counts: delay-mult product ≈ 48²/128 = 18,
    # which gives enough SNR for the FIR and inner DC removal to work.
    # Below ~48 counts (e.g., 32) the signal is lost in quantisation noise.
    adc_12bit = _make_adc_samples('APRS', 'N0CALL', [], b'>Low amplitude test', 48)
    ok = run_test_inner("12-bit ADC low amplitude (48 counts, near threshold)",
                        adc_12bit.tolist(), use_adc_pipeline=True, verbose=verbose)
    results.append(ok)

    # --- Below-threshold level: 32 counts p-p (informational — expect fail) ---
    adc_12bit_low = _make_adc_samples('APRS', 'N0CALL', [], b'>Below threshold', 32)
    state_low = DecoderState()
    process_adc_samples(state_low, adc_12bit_low.tolist())
    # 32 counts p-p: delay-mult product ≈ 16²/128 = 2 counts → below demod threshold.
    below_status = PASS_STR if state_low.crc_ok == 0 else FAIL_STR
    print(f"  [{below_status}] 12-bit ADC below threshold (32 counts, expect fail): "
          f"crc_ok={state_low.crc_ok} (demod minimum ~48 counts p-p)")

    # --- Over-driven / clipped signal (informational — may or may not decode) ---
    # Over-driving produces hard-limited square waves at 1200/2200 Hz.
    # These still contain frequency information so decoding is possible.
    frame = ax25_build_ui_frame('APRS', 'N0CALL', [], b'>Clipping test')
    bits  = hdlc_frame_bits(frame, num_preamble=50, num_tail=5)
    nrzi  = nrzi_encode(bits)
    audio = afsk_modulate_9600(nrzi)
    silence = np.full(int(0.1 * APRS_SAMPLE_RATE_HZ), 2048.0)
    adc_float = np.concatenate([silence, audio * 2200.0 + 2048.0])  # rail-to-rail
    adc_12bit = np.clip(np.round(adc_float), 0, 4095).astype(np.int32)

    state_clip = DecoderState()
    process_adc_samples(state_clip, adc_12bit.tolist())
    status = PASS_STR if state_clip.crc_ok > 0 else FAIL_STR
    print(f"  [{status}] 12-bit ADC clipped (over-driven, informational): "
          f"crc_ok={state_clip.crc_ok}")
    # Not appended to results — clipping may or may not decode

    return all(results)


# ===========================================================================
# Test 5 — Edge cases
# ===========================================================================

def test_edge_cases(verbose: bool = False) -> bool:
    print("\nTest 5: Edge cases")
    results = []

    # Minimum-length valid frame: dest(7)+src(7)+ctrl(1)+pid(1)+info(2)+fcs(2) = 20 bytes
    samples = make_afsk_samples('APRS', 'N0CALL', [], b'!!')
    ok = run_test_inner("Minimum-length frame (2-byte info)", samples.tolist(), verbose=verbose)
    results.append(ok)

    # Multi-hop path
    samples = make_afsk_samples('APRS', 'N0CALL', ['RELAY', 'WIDE1', 'WIDE2'],
                                b'>Multi-hop test')
    ok = run_test_inner("Multi-hop path (3 digipeaters)", samples.tolist(), verbose=verbose)
    results.append(ok)

    # APRS position packet
    samples = make_afsk_samples('APRS', 'KA1TST', ['WIDE1-1', 'WIDE2-1'],
                                b'!4903.50N/07201.75W-Test')
    ok = run_test_inner("Position packet with WIDE path", samples.tolist(), verbose=verbose)
    results.append(ok)

    # Consecutive flags only — should see flags but no valid frame
    flag_audio = afsk_modulate_9600(nrzi_encode([0, 1, 1, 1, 1, 1, 1, 0] * 100))
    flag_samples = (flag_audio * 1000).astype(np.int16)
    state = DecoderState()
    for s in flag_samples:
        feed_sample(state, int(s))
    ok_flags = state.flag_seen > 0 and state.crc_ok == 0
    status = PASS_STR if ok_flags else FAIL_STR
    print(f"  [{status}] Flags-only: flags={state.flag_seen} crc_ok={state.crc_ok} "
          f"(expect flags>0, crc_ok=0)")
    results.append(ok_flags)

    return all(results)


# ===========================================================================
# Test 6 — CRC validation
# ===========================================================================

def test_crc_validation(verbose: bool = False) -> bool:
    print("\nTest 6: CRC validation")
    results = []

    info  = b'>CRC test packet'
    frame = ax25_build_ui_frame('APRS', 'N0CALL', [], info)

    # Valid frame → must be accepted
    samples = make_afsk_samples('APRS', 'N0CALL', [], info)
    state_ok = DecoderState()
    for s in samples:
        feed_sample(state_ok, int(s))
    ok1 = state_ok.crc_ok == 1
    status = PASS_STR if ok1 else FAIL_STR
    print(f"  [{status}] Valid frame accepted: crc_ok={state_ok.crc_ok}")
    results.append(ok1)

    # Frame with wrong FCS → must be rejected.
    # Build a valid frame, compute its correct FCS, then transmit it with a
    # deliberately incorrect FCS appended so the receiver's CRC residue check
    # will fail.  We must encode the WRONG FCS ourselves inside the HDLC frame
    # rather than re-computing from the data (which would produce a valid FCS).
    fcs_correct = crc16(frame)
    fcs_wrong   = fcs_correct ^ 0x1234          # flip some bits in the FCS
    full_bad    = frame + struct.pack('<H', fcs_wrong)
    # Build HDLC bit stream manually (without re-computing FCS)
    flag_bits = [0, 1, 1, 1, 1, 1, 1, 0]
    raw_bits  = bytes_to_bits_lsb(full_bad)
    stuffed   = bit_stuff(raw_bits)
    bits_bad  = flag_bits * 50 + stuffed + flag_bits * 5
    nrzi_bad  = nrzi_encode(bits_bad)
    audio_bad = afsk_modulate_9600(nrzi_bad)
    samples_bad = (audio_bad * 1000).astype(np.int16)

    state_bad = DecoderState()
    for s in samples_bad:
        feed_sample(state_bad, int(s))
    ok2 = state_bad.crc_ok == 0 and state_bad.crc_fail > 0
    status = PASS_STR if ok2 else FAIL_STR
    print(f"  [{status}] Wrong-FCS frame rejected: "
          f"crc_ok={state_bad.crc_ok} crc_fail={state_bad.crc_fail}")
    results.append(ok2)

    # CRC residue check: feeding all frame bytes including FCS gives 0xF0B8
    fcs = crc16(frame)
    full = frame + struct.pack('<H', fcs)
    crc_run = 0xFFFF
    for b in full:
        crc_run = crc16_update(crc_run, b)
    ok3 = crc_run == APRS_AX25_CRC_CORRECT
    status = PASS_STR if ok3 else FAIL_STR
    print(f"  [{status}] CRC residue 0xF0B8: got 0x{crc_run:04X}")
    results.append(ok3)

    return all(results)


# ===========================================================================
# Test 7 — FIR coefficient sanity check
# ===========================================================================

def test_fir_coefficients(verbose: bool = False) -> bool:
    print("\nTest 7: FIR coefficient sanity check")
    coeffs = design_fir_lowpass()
    mid = APRS_FIR_TAPS // 2
    results = []

    ok = len(coeffs) == APRS_FIR_TAPS
    status = PASS_STR if ok else FAIL_STR
    print(f"  [{status}] Length: {len(coeffs)} (expected {APRS_FIR_TAPS})")
    results.append(ok)

    ok = abs(coeffs[mid]) == max(abs(c) for c in coeffs)
    status = PASS_STR if ok else FAIL_STR
    print(f"  [{status}] Centre tap max: coeff[{mid}]={coeffs[mid]}")
    results.append(ok)

    ok = all(coeffs[i] == coeffs[APRS_FIR_TAPS - 1 - i] for i in range(mid))
    status = PASS_STR if ok else FAIL_STR
    print(f"  [{status}] Symmetric (linear phase)")
    results.append(ok)

    dc_gain = sum(coeffs) / 32767.0
    ok = 0.8 < dc_gain < 1.2
    status = PASS_STR if ok else FAIL_STR
    print(f"  [{status}] DC gain: {dc_gain:.4f} (expected ~1.0)")
    results.append(ok)

    if verbose:
        print(f"         Coefficients: {coeffs}")

    return all(results)


# ===========================================================================
# Test 8 — Demod parameter sanity check
# ===========================================================================

def test_demod_parameters(verbose: bool = False) -> bool:
    print("\nTest 8: Demodulator parameter sanity check")
    results = []

    checks = [
        ("APRS_DEMOD_DELAY",   APRS_DEMOD_DELAY,   4),
        ("APRS_SAMPLES_PER_BIT", APRS_SAMPLES_PER_BIT, 8),
        ("APRS_PHASE_MAX",     APRS_PHASE_MAX,     64),
        ("APRS_PHASE_THRESHOLD", APRS_PHASE_THRESHOLD, 32),
        ("APRS_PHASE_BITS",    APRS_PHASE_BITS,     8),
        ("APRS_PHASE_INC",     APRS_PHASE_INC,      2),
        ("APRS_FIR_TAPS",      APRS_FIR_TAPS,      31),
    ]

    for name, got, expected in checks:
        ok = got == expected
        status = PASS_STR if ok else FAIL_STR
        print(f"  [{status}] {name} = {got} (expected {expected})")
        results.append(ok)

    # Discriminator frequency response
    D  = APRS_DEMOD_DELAY
    Fs = APRS_SAMPLE_RATE_HZ
    dc_space = 0.5 * math.cos(2 * math.pi * APRS_SPACE_FREQ_HZ * D / Fs)
    dc_mark  = 0.5 * math.cos(2 * math.pi * APRS_MARK_FREQ_HZ  * D / Fs)
    ok = (dc_space > 0) and (dc_mark < 0)
    status = PASS_STR if ok else FAIL_STR
    print(f"  [{status}] Discriminator distinguishes tones: "
          f"space DC={dc_space:.3f} (>0), mark DC={dc_mark:.3f} (<0)")
    results.append(ok)

    return all(results)


# ===========================================================================
# Main
# ===========================================================================

def main():
    parser = argparse.ArgumentParser(
        description='AFSK demodulator test suite — ESP32 C demod replica in Python')
    parser.add_argument('--verbose', '-v', action='store_true',
                        help='Print detailed decode info for every test')
    parser.add_argument('--wav', default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), 'direwolf_ref.wav'),
        help='Path to Direwolf-generated WAV for Test 2')
    args = parser.parse_args()

    print("=" * 65)
    print("AFSK Demodulator Test Suite  (ESP32 C demod replica)")
    print(f"  Sample rate    : {APRS_SAMPLE_RATE_HZ} Hz")
    print(f"  Baud rate      : {APRS_BITRATE_BPS} bps")
    print(f"  Mark / Space   : {APRS_MARK_FREQ_HZ:.0f} / {APRS_SPACE_FREQ_HZ:.0f} Hz")
    print(f"  Delay taps     : {APRS_DEMOD_DELAY}")
    print(f"  FIR taps       : {APRS_FIR_TAPS}  (Hamming, Fc=1200 Hz)")
    print(f"  PLL PHASE_MAX  : {APRS_PHASE_MAX}")
    print(f"  Max safe ampl. : {DEMOD_MAX_AMP} counts (delay-mult overflow limit)")
    print("=" * 65)

    tests = [
        ("Demod parameters",     lambda: test_demod_parameters(args.verbose)),
        ("FIR coefficients",     lambda: test_fir_coefficients(args.verbose)),
        ("CRC validation",       lambda: test_crc_validation(args.verbose)),
        ("Clean synthetic AFSK", lambda: test_clean_synthetic(args.verbose)),
        ("Direwolf WAV",         lambda: test_direwolf_wav(args.wav, args.verbose)),
        ("aprs_tx encoder",      lambda: test_aprs_tx_encoder(args.verbose)),
        ("ADC conditions",       lambda: test_adc_conditions(args.verbose)),
        ("Edge cases",           lambda: test_edge_cases(args.verbose)),
    ]

    passed = 0
    failed = 0

    for name, fn in tests:
        try:
            result = fn()
            if result:
                passed += 1
            else:
                failed += 1
        except Exception as exc:
            print(f"\n  [ERROR] {name}: {exc}")
            if args.verbose:
                import traceback
                traceback.print_exc()
            failed += 1

    print("\n" + "=" * 65)
    total = passed + failed
    if failed == 0:
        print(f"Results: {passed}/{total} test groups  PASSED")
    else:
        print(f"Results: {passed}/{total} test groups passed  "
              f"({failed} FAILED)")
    print("=" * 65)

    sys.exit(0 if failed == 0 else 1)


if __name__ == '__main__':
    main()
