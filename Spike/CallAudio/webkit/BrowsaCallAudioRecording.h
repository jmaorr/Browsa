// Development WebKit builds only: copy next to BrowsaCallAudioInternalUnit.h to compile in call recording (the debug
// dump, BROWSA_CALL_AUDIO_DUMP). A WebKit built for release leaves this file out, so its unit can't record.
#pragma once
#define BROWSA_CALL_AUDIO_RECORDING 1
