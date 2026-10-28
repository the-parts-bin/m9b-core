// Renders a MIDI-like song (MID, XMI, MUS, ... whatever libADLMIDI reads)
// to a 32-bit float stereo WAV file (quiet songs keep their resolution
// through finish.py's gain) with libADLMIDI's Nuked OPL3 emulation, for
// the ports that stream pre-rendered music (Descent, Ultima VII, System
// Shock; Doom and Tyrian have their own renderers).
//
// Usage: midirender IN OUT.WAV [options]
//   -b NAME|N   embedded bank by name or number (-l lists them), default 0
//   -w FILE     a WOPL bank file instead
//   -a FILE     then an AIL global timbre library (Miles' .AD, e.g. Ultima
//               VII's XMIDI.AD) over it: its 2-operator timbres replace
//               the bank's instruments (bank 127: drums, by note)
//   -v MODEL    volume model: generic, native, dmx, apogee, win9x, hmi, ail
//   -c N        OPL3 chips (default 1)
//   -t N        XMI/multi-song files: song N (default 0)
//   -r RATE     sample rate (default 48000)
//   -s SEC      stop after SEC seconds (default: the end; no looping)
//   -l          list the embedded banks and exit
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "adlmidi.h"

static void wr32(FILE *f, uint32_t v) { fputc(v, f); fputc(v >> 8, f); fputc(v >> 16, f); fputc(v >> 24, f); }
static void wr16(FILE *f, uint32_t v) { fputc(v, f); fputc(v >> 8, f); }

static void wav_header(FILE *f, uint32_t rate, uint32_t frames) {   // float, stereo
    uint32_t bytes = frames * 8u;
    fwrite("RIFF", 1, 4, f); wr32(f, 36u + bytes); fwrite("WAVEfmt ", 1, 8, f);
    wr32(f, 16); wr16(f, 3); wr16(f, 2); wr32(f, rate); wr32(f, rate * 8u); wr16(f, 8); wr16(f, 32);
    fwrite("data", 1, 4, f); wr32(f, bytes);
}

// An AIL global timbre library: entries {patch, bank, offset (32-bit)}
// until bank 0xFF; at each offset a timbre: its size (16-bit, 14 for the
// 2-operator ones), the transpose (for drums, bank 127: the note to play),
// the modulator's 20/40/60/80/E0 registers, C0 (feedback, connection) and
// the carrier's. Other sizes (TVFX effects, 4-operator) are skipped.
static void load_ail(struct ADL_MIDIPlayer *p, const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(1); }
    static unsigned char d[1 << 20];
    size_t n = fread(d, 1, sizeof(d), f);
    fclose(f);
    int loaded = 0, skipped = 0;
    for (size_t i = 0; i + 6 <= n && d[i + 1] != 0xFF; i += 6) {
        unsigned patch = d[i], bank = d[i + 1];
        size_t off = d[i + 2] | d[i + 3] << 8 | (size_t)d[i + 4] << 16 | (size_t)d[i + 5] << 24;
        if (off + 14 > n || (d[off] | d[off + 1] << 8) != 14) { skipped++; continue; }
        const unsigned char *t = d + off + 2;
        ADL_BankId id = {bank == 127, 0, bank == 127 ? 0 : (unsigned char)bank};
        ADL_Bank b;
        ADL_Instrument ins;
        if (adl_getBank(p, &id, ADLMIDI_Bank_Create, &b) < 0) { fprintf(stderr, "bank: %s\n", adl_errorInfo(p)); exit(1); }
        memset(&ins, 0, sizeof(ins));
        if (bank == 127) ins.percussion_key_number = t[0];
        else ins.note_offset1 = (signed char)t[0];
        ins.fb_conn1_C0 = t[6];
        ins.operators[1] = (ADL_Operator){t[1], t[2], t[3], t[4], t[5]};    // modulator
        ins.operators[0] = (ADL_Operator){t[7], t[8], t[9], t[10], t[11]};  // carrier
        ins.delay_on_ms = 5000;
        ins.delay_off_ms = 500;
        adl_setInstrument(p, &b, patch, &ins);
        loaded++;
    }
    fprintf(stderr, "%s: %d timbres, %d skipped\n", path, loaded, skipped);
}

static int volume_model(const char *s) {
    static const struct { const char *name; int model; } m[] = {
        {"generic", ADLMIDI_VolumeModel_Generic}, {"native", ADLMIDI_VolumeModel_NativeOPL3},
        {"dmx", ADLMIDI_VolumeModel_DMX}, {"apogee", ADLMIDI_VolumeModel_APOGEE},
        {"win9x", ADLMIDI_VolumeModel_9X}, {"hmi", ADLMIDI_VolumeModel_HMI},
        {"ail", ADLMIDI_VolumeModel_AIL}};
    for (size_t i = 0; i < sizeof(m) / sizeof(*m); i++)
        if (strcmp(s, m[i].name) == 0) return m[i].model;
    fprintf(stderr, "unknown volume model %s\n", s);
    exit(1);
}

int main(int argc, char **argv) {
    const char *bank = "0", *wopl = NULL, *vol = NULL, *ail = NULL;
    long rate = 48000, chips = 1, song = 0;
    double seconds = 0;
    int c;
    while ((c = getopt(argc, argv, "b:w:a:v:c:t:r:s:l")) != -1) {
        switch (c) {
        case 'b': bank = optarg; break;
        case 'w': wopl = optarg; break;
        case 'a': ail = optarg; break;
        case 'v': vol = optarg; break;
        case 'c': chips = atol(optarg); break;
        case 't': song = atol(optarg); break;
        case 'r': rate = atol(optarg); break;
        case 's': seconds = atof(optarg); break;
        case 'l': {
            const char *const *names = adl_getBankNames();
            for (int i = 0; i < adl_getBanksCount(); i++) printf("%3d %s\n", i, names[i]);
            return 0;
        }
        default: return 1;
        }
    }
    if (argc - optind != 2) {
        fprintf(stderr, "usage: %s IN OUT.WAV [-b BANK] [-w WOPL] [-a AIL.AD] [-v MODEL] [-c CHIPS] [-t SONG] [-r RATE] [-s SEC] | -l\n", argv[0]);
        return 1;
    }
    struct ADL_MIDIPlayer *p = adl_init(rate);
    adl_switchEmulator(p, ADLMIDI_EMU_NUKED);
    adl_setNumChips(p, (int)chips);
    if (wopl) {
        if (adl_openBankFile(p, wopl) < 0) { fprintf(stderr, "%s: %s\n", wopl, adl_errorInfo(p)); return 1; }
    } else {
        int n = -1;
        const char *const *names = adl_getBankNames();
        for (int i = 0; i < adl_getBanksCount(); i++)
            if (strcmp(names[i], bank) == 0) n = i;
        if (n < 0) n = atoi(bank);
        adl_setBank(p, n);
    }
    if (vol) adl_setVolumeRangeModel(p, volume_model(vol));
    adl_setSoftPanEnabled(p, 0);
    adl_setLoopEnabled(p, 0);
    if (adl_openFile(p, argv[optind]) < 0) { fprintf(stderr, "%s: %s\n", argv[optind], adl_errorInfo(p)); return 1; }
    if (song) adl_selectSongNum(p, (int)song);
    if (ail) load_ail(p, ail);   // after opening: that reloads the embedded bank
    FILE *o = fopen(argv[optind + 1], "wb");
    if (!o) { perror(argv[optind + 1]); return 1; }
    wav_header(o, (uint32_t)rate, 0);
    static float buf[2 * 4096];
    const struct ADLMIDI_AudioFormat fmt = {ADLMIDI_SampleType_F32, sizeof(float), 2 * sizeof(float)};
    uint32_t frames = 0, limit = seconds > 0 ? (uint32_t)(seconds * rate) : UINT32_MAX;
    float peak = 0;
    while (!adl_atEnd(p) && frames < limit) {
        int n = adl_playFormat(p, 2 * 4096, (ADL_UInt8 *)buf, (ADL_UInt8 *)(buf + 1), &fmt);
        if (n <= 0) break;
        for (int k = 0; k < n; k++) if (fabsf(buf[k]) > peak) peak = fabsf(buf[k]);
        fwrite(buf, 4, n, o);
        frames += (uint32_t)n / 2u;
    }
    fseek(o, 0, SEEK_SET);
    wav_header(o, (uint32_t)rate, frames);
    fclose(o);
    printf("%s: %.1f s, peak %.1f dBFS\n", argv[optind + 1], frames / (double)rate, peak > 0 ? 20 * log10f(peak) : -999.0);
    adl_close(p);
    return 0;
}
