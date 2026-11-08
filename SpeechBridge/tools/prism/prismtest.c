/* prismtest: repeats the SAPI calls the Prism library makes (as in Fallout 4 Access) and prints
 * each result, so the point where Wine or the SpeechBridge stand-ins fall short is visible. */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <sapi.h>
#include <sperror.h>
#include <stdio.h>
static void say(const char *what, HRESULT hr) { printf("%-52s %s (0x%08lx)\n", what, SUCCEEDED(hr) ? "ok" : "FAILED", (unsigned long)hr); fflush(stdout); }
int main(void) {
    IClassFactory *cf = NULL; HRESULT hr;
    hr = CoGetClassObject(&CLSID_SpVoice, CLSCTX_INPROC_SERVER | CLSCTX_LOCAL_SERVER, NULL, &IID_IClassFactory, (void **)&cf);
    say("CoGetClassObject(SpVoice) BEFORE CoInitialize", hr); if (cf) { IClassFactory_Release(cf); cf = NULL; }
    hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_SPEED_OVER_MEMORY); say("CoInitializeEx(apartment)", hr);
    hr = CoGetClassObject(&CLSID_SpVoice, CLSCTX_INPROC_SERVER | CLSCTX_LOCAL_SERVER, NULL, &IID_IClassFactory, (void **)&cf);
    say("CoGetClassObject(SpVoice) after CoInitialize", hr); if (cf) IClassFactory_Release(cf);
    ISpVoice *v = NULL;
    hr = CoCreateInstance(&CLSID_SpVoice, NULL, CLSCTX_ALL, &IID_ISpVoice, (void **)&v); say("CoCreateInstance(SpVoice)", hr);
    if (!v) return 1;
    IStream *st = NULL; hr = CoMarshalInterThreadInterfaceInStream(&IID_ISpVoice, (IUnknown *)v, &st); say("CoMarshalInterThreadInterfaceInStream", hr); if (st) IStream_Release(st);
    ISpObjectTokenCategory *cat = NULL;
    hr = CoCreateInstance(&CLSID_SpObjectTokenCategory, NULL, CLSCTX_ALL, &IID_ISpObjectTokenCategory, (void **)&cat); say("CoCreateInstance(SpObjectTokenCategory)", hr);
    if (cat) {
        hr = ISpObjectTokenCategory_SetId(cat, SPCAT_VOICES, FALSE); say("category SetId(SPCAT_VOICES)", hr);
        IEnumSpObjectTokens *en = NULL; hr = ISpObjectTokenCategory_EnumTokens(cat, NULL, NULL, &en); say("EnumTokens", hr);
        if (en) { ULONG n = 0; hr = IEnumSpObjectTokens_GetCount(en, &n); printf("  %lu voice token(s)\n", n);
            for (ULONG i = 0; i < n; i++) { ISpObjectToken *t = NULL; if (FAILED(IEnumSpObjectTokens_Next(en, 1, &t, NULL)) || !t) break;
                LPWSTR name = NULL, lang = NULL; HRESULT h1 = ISpObjectToken_GetStringValue(t, NULL, &name); HRESULT h2 = ISpObjectToken_GetStringValue(t, L"Language", &lang);
                printf("  token %lu: name %s '%ls' language %s '%ls'\n", i, SUCCEEDED(h1) ? "ok" : "FAILED", name ? name : L"", SUCCEEDED(h2) ? "ok" : "FAILED", lang ? lang : L"");
                if (name) CoTaskMemFree(name); if (lang) CoTaskMemFree(lang); ISpObjectToken_Release(t); }
            IEnumSpObjectTokens_Release(en); }
        ISpObjectTokenCategory_Release(cat);
    }
    ISpObjectToken *cur = NULL; hr = ISpVoice_GetVoice(v, &cur); say("voice->GetVoice", hr); if (cur) ISpObjectToken_Release(cur);
    ISpStreamFormat *fmt = NULL; hr = ISpVoice_GetOutputStream(v, &fmt); say("voice->GetOutputStream", hr);
    if (fmt) { GUID g; WAVEFORMATEX *w = NULL; hr = ISpStreamFormat_GetFormat(fmt, &g, &w); say("stream->GetFormat", hr); if (w) { printf("  format tag %u ch %u rate %lu bits %u\n", w->wFormatTag, w->nChannels, w->nSamplesPerSec, w->wBitsPerSample); CoTaskMemFree(w); } ISpStreamFormat_Release(fmt); }
    USHORT vol = 0; hr = ISpVoice_GetVolume(v, &vol); say("voice->GetVolume", hr);
    long rate = 0; hr = ISpVoice_GetRate(v, &rate); say("voice->GetRate", hr);
    hr = ISpVoice_Speak(v, L"Prism test through SpeechBridge", SPF_ASYNC | SPF_IS_NOT_XML, NULL); say("voice->Speak(async)", hr);
    SPVOICESTATUS s; hr = ISpVoice_GetStatus(v, &s, NULL); say("voice->GetStatus", hr);
    ISpVoice_Release(v); CoUninitialize(); return 0;
}
