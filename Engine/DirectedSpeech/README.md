# Engine/DirectedSpeech (P5.1)

Always-on lightweight path: `RollingAudioRing` (10 s, RAM only) ← audio; `VADEvent`s → `DirectedSpeechDetector`
→ `DirectedSpeechFeatureExtractor` (prosody: SNR, level, energy slope, autocorr voicing, ZCR, onset rate;
content: `KeywordSpotter` over the streaming preview; context: text field focused / addressed recently)
→ `DirectedSpeechClassifier` (logistic regression, hand-initialised weights, online "not you" updates).

`DirectedSpeechHarness` scores `Fixtures/directed/manifest.json` (clean = addressed, noisy/far-field/vad-floor
= ambient). Ship bar `< 1 false trigger/day` (simulated, 400 ambient utterances/day); below bar the mode stays
behind `DirectedSpeechFlags.experimentalModeID` (default off). Nothing persisted, nothing transmitted.
