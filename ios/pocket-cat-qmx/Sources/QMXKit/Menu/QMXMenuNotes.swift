// Human explanations for the QMX menu tree, keyed by display path
// (lowercased, |-joined). The tree itself is discovered LIVE from the
// radio via MM/ML — this catalog only overlays descriptions, so firmware
// menu additions still appear in the app (with a generic note) before
// this file learns about them.
//
// Sources: QMX operating manual (QRP Labs) and the CAT programming manual
// fw 1_02_006. Values in brackets are factory defaults where stable.

import Foundation

public enum QMXMenuNotes {
    /// Explanation for a node, or a friendly generic fallback.
    public static func note(forPath path: [String]) -> String? {
        notes[path.map { $0.lowercased() }.joined(separator: "|")]
    }

    public static let fallback =
        "Discovered live from the radio's menu tree. No write-up for this "
        + "item yet — consult the QMX operating manual for details."

    // swiftlint:disable line_length
    static let notes: [String: String] = [
        // MARK: Top level
        "audio":
            "Receive audio behavior: AGC, sidetone, and audio routing. These shape what you hear, not what you transmit.",
        "display":
            "Screen preferences — brightness, contrast, and what the two LCD rows show while operating.",
        "cw":
            "Everything CW: keyer behavior, speed, sidetone, receive filters, and the built-in CW decoder.",
        "digi interface":
            "Digital-mode settings for use with WSJT-X/JS8Call over the USB sound card: how key-down is detected from audio and how the radio shapes the RF envelope.",
        "system config":
            "Radio-wide plumbing: CAT serial behavior, real-time clock, TS-480 compatibility, and factory maintenance actions.",
        "band config.":
            "The per-band table (one column per band): frequency limits, RF gain, band-pass/low-pass filter selection, PA bias, and PTT routing. Edits here retune how the radio behaves on each band — change with care.",
        "beacon":
            "Automatic beacon transmissions (CW or WSPR). Configure mode, timing, and the transmitted message/callsign.",
        "hardware tests":
            "Factory and diagnostic tools (signal generator, sweeps, terminal apps). Actions here can transmit or overwrite calibration — use deliberately.",

        // MARK: Audio
        "audio|agc settings":
            "Automatic Gain Control: how receive gain rides signal strength so loud signals don't blast and weak ones stay audible.",
        "audio|agc settings|agc enable":
            "Master switch for the AGC. OFF means manual gain only — strong signals will be LOUD.",
        "audio|agc settings|threshold s":
            "Signal level (S-points) where the AGC starts holding gain back. Lower engages sooner (quieter band noise); higher lets weak-signal dynamics through untouched. [S-4]",
        "audio|agc settings|attack":
            "How fast gain drops when a strong signal appears. Faster protects your ears on pile-ups; too fast can pump on CW.",
        "audio|agc settings|decay":
            "How fast gain recovers after a strong signal ends. Slow decay sounds smooth; fast decay recovers weak stations sooner.",
        "audio|agc settings|hang":
            "Hold time before decay begins. A little hang stops the background 'breathing' between CW elements.",
        "audio|sidetone volume":
            "Loudness of the CW sidetone (your own keying) in your ear. Does not affect transmitted power.",
        "audio|sidetone frequency":
            "Pitch of the sidetone, and therefore your TX offset when you tune a station to the same pitch. Most CW ops pick 500–700 Hz.",

        // MARK: CW
        "cw|cw keyer":
            "The electronic keyer that turns paddle contacts into dits and dahs.",
        "cw|cw keyer|keyer mode":
            "Straight = the key is a manual switch. IAMBIC A/B = squeeze keying with both paddles (B adds an extra alternating element on release). Ultimatic = last-pressed paddle wins. [IAMBIC A]",
        "cw|cw keyer|keyer speed":
            "Sending speed in words per minute. Also settable from the CAT `KS` command and used for `KY` message keying. [20]",
        "cw|cw keyer|keyer swap":
            "Swap dit and dah paddles — for left-handed keying or miswired cables.",
        "cw|cw keyer|keyer weight":
            "Dit:space ratio. 500 = classic 1:1. Heavier weight sounds 'fatter' at speed.",
        "cw|cw decoder":
            "The built-in CW decoder: it prints received (and optionally transmitted) Morse on screen and over CAT (`TB` command).",
        "cw|cw decoder|enable rx decode":
            "Decode incoming CW to text on the display. Handy for checking your copy — imperfect on weak or sloppy signals, like every decoder.",
        "cw|cw decoder|enable tx decode":
            "Also decode your own transmitted keying — a live check of your paddle sending.",
        "cw|choose filters":
            "Which CW receive filter bandwidths are offered when you cycle filters from the front panel. Each row is one width (Hz), enabled or disabled.",
        "cw|qsk delay":
            "Delay before the receiver comes back between elements (semi break-in). Shorter feels like full QSK; longer avoids relay chatter.",
        "cw|practice mode":
            "Key the sidetone WITHOUT transmitting RF. Perfect for code practice or testing a keyer setup safely.",

        // MARK: Digi
        "digi interface|rise threshold":
            "Percentage of the detected audio amplitude that counts as key-down when transmitting digital modes from the sound card. Default 80 works for WSJT-X; lower if TX doesn't trigger. [80]",
        "digi interface|fall threshold":
            "Amplitude percentage below which the radio keys up (stops transmitting). Keep below the rise threshold for clean switching. [60]",
        "digi interface|cycle min":
            "Minimum audio cycles measured before the radio trusts a tone frequency — raises accuracy at the cost of key-down latency.",
        "digi interface|sample min":
            "Minimum ADC samples per measurement window for tone detection.",
        "digi interface|discard":
            "Measurement windows thrown away after key-down before the tone is trusted — rejects the ragged start of a transmission.",
        "digi interface|iq mode":
            "Stream raw I/Q samples to the USB sound card instead of demodulated audio — turns the QMX into a direct-sampling SDR front end for host software. Session-only via CAT `Q9`.",

        // MARK: System config
        "system config|cat":
            "How the serial/CAT interface behaves — baud, timeouts, and command compatibility.",
        "system config|cat|serial baud":
            "Baud rate for the physical serial ports. The USB Virtual COM ports ignore this (USB CDC line coding is cosmetic) — which is why the Pocket Cat bridge works at any rate. [115200]",
        "system config|cat|cat timeout enable":
            "If ON, an in-progress CAT-commanded transmission is aborted when no CAT traffic arrives for the timeout period — a dead-host failsafe on top of the bridge's own. (CAT `QB`.)",
        "system config|cat|cat timeout":
            "Seconds of CAT silence before the timeout (above) unkeys the radio. (CAT `QC`.)",
        "system config|cat|cat ru and rd":
            "Whether the CAT `RU`/`RD` RIT commands set an absolute offset or nudge the current one. Affects how this app's RIT buttons behave.",
        "system config|cat|ts480 compat":
            "Strict Kenwood TS-480 emulation for the `KY` keying command (fixed 24-char messages). Leave OFF for this app; turn ON only if some host software insists.",
        "system config|real time clock":
            "The QMX keeps wall-clock time (CAT `TM`) for beacon scheduling. It resets at power-off unless the hardware clock mod is fitted.",
        "system config|factory reset":
            "Wipes ALL configuration back to defaults — including band tables and calibration adjustments. There is no undo; save a profile first.",
        "system config|tcxo frequency":
            "The reference oscillator's actual frequency (nominally 25 MHz). Adjusting it calibrates the radio's frequency accuracy (CAT `Q0` for session-only experiments).",
        "system config|vox":
            "Voice/tone-operated switching: key the transmitter automatically when input audio appears (CAT `Q3`). Mostly useful for digital modes without CAT PTT.",
        "system config|japanese band limits":
            "Restricts transmission to the Japanese amateur band plan (CAT `QA`).",

        // MARK: Band config columns
        "band config.|band name (m)":
            "Which amateur band (in meters) this column configures — 160 through 6, per the bands your QMX's filter board supports.",
        "band config.|rf gain (db)":
            "Receiver front-end gain for the band. Too high can overload on strong-signal bands (40 m at night); too low costs sensitivity.",
        "band config.|frequency min.":
            "Lower edge (Hz) of the tuning range the radio permits on this band.",
        "band config.|frequency center":
            "Default/center frequency (Hz) — where the VFO lands when you switch to this band.",
        "band config.|frequency max.":
            "Upper edge (Hz) of the permitted tuning range for this band.",
        "band config.|sweep start":
            "Start frequency for the built-in sweep tools on this band.",
        "band config.|sweep step":
            "Step size for the sweep tools on this band.",
        "band config.|bpf number (0-7)":
            "Which band-pass filter the receiver switches in for this band. Must match the filter actually fitted at that position — a wrong BPF deafens the band.",
        "band config.|lpf number (0-5)":
            "Which low-pass filter the transmitter uses on this band. ⚠️ A wrong LPF transmits harmonics and can damage the PA.",
        "band config.|pin fwd bias ma":
            "Forward bias current for the TX/RX switching PIN diodes on this band.",
        "band config.|transmit":
            "Master allow/deny for transmitting on this band — disable bands whose filters aren't fitted.",
        "band config.|tx ptt +5v":
            "Drive the PTT jack with +5 V while transmitting on this band (for switching an external amplifier).",
        "band config.|tx ptt grounded":
            "Ground the PTT jack while transmitting on this band (the common amplifier keying convention).",
        "band config.|rx ptt +5v":
            "Drive the PTT jack with +5 V while receiving on this band.",
        "band config.|rx ptt grounded":
            "Ground the PTT jack while receiving on this band.",

        // MARK: Beacon
        "beacon|beacon enable":
            "Master switch for automatic beacon transmissions. Remember: a beacon transmits unattended — check the band plan and your license conditions.",
        "beacon|mode":
            "What the beacon sends: CW or WSPR (weak-signal propagation reporter).",
        "beacon|frequency":
            "Beacon transmit frequency in Hz. For WSPR, use the standard sub-band for your band.",
        "beacon|callsign":
            "Your callsign as transmitted by the beacon (WSPR encodes it; CW sends it literally).",
        "beacon|locator":
            "Maidenhead grid square transmitted in WSPR beacons.",
        "beacon|power dbm":
            "The power level WSPR reports in its message — set it to your actual output (37 dBm = 5 W) so spots are honest.",
        "beacon|start minute":
            "Which minutes of the hour the beacon fires — WSPR slots are even minutes, 110.6 s long.",
    ]
    // swiftlint:enable line_length
}
