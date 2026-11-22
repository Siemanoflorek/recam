# RealCam · nasłuch (audio)

iPhone jako zdalny mikrofon. Telefon łączy się po Wi-Fi z serwerem na PC
i wysyła dźwięk na żywo; serwer liczy głośność i może odpalić alert.

```
iPhone (mikrofon)  --- Wi-Fi / WebSocket --->  PC (serwer Python)  --->  przeglądarka + alert
```

**Najważniejsze:** audio iOS pozwala nagrywać **w tle** — możesz zablokować
telefon / zgasić ekran, a nasłuch działa dalej. (To czego NIE dało się zrobić
z kamerą.) Jedyny ślad: pomarańczowa kropka w pasku stanu, gdy mikrofon jest
aktywny — przy zgaszonym ekranie i tak jej nie widać.

## Co jest w środku
- `server/` – serwer na PC (Python): odbiór audio, miernik głośności, próg alertu.
- `ios/` – aplikacja na iPhone (Swift/SwiftUI).
- `.github/workflows/build-ipa.yml` – budowanie `.ipa` na GitHubie.

---

## 1. Serwer na PC (Windows 11)

```bat
cd server
pip install -r requirements.txt
python server.py
```

Serwer wypisze IP tego komputera, np. `192.168.1.42`.
- Podgląd: `http://localhost:8000` (miernik głośności + wskaźnik alertu).
- Przy pierwszym uruchomieniu **zezwól w zaporze Windows** (sieci prywatne).

### Twój alert
W `server/server.py` szukaj linii:
```python
# >>> TU WEPNIJ SWÓJ ALERT (mail, powiadomienie, zapis pliku...) <<<
```
Tam wpada kod, gdy głośność przekroczy `LOUD_THRESHOLD` (0.0–1.0, domyślnie 0.5).
Masz gotowy `level` (0–1) i `loud` (True/False) do wykorzystania.

## 2. Zbuduj `.ipa` (bez Maca)

1. Wrzuć folder do **nowego repo na GitHubie** (publiczne = budowanie za darmo).
2. **Actions** → uruchom **„Build unsigned IPA"** (albo `push`).
3. Pobierz artefakt **RealCam-unsigned-ipa** → `RealCam.ipa` (niepodpisana).

## 3. Podpisz i zainstaluj przez AltStore

1. AltServer na PC + AltStore na telefonie.
2. AltStore → **My Apps → +** → wskaż `RealCam.ipa` → podaj Apple ID (najlepiej
   zapasowy). AltStore podpisze aplikację Twoim kontem.
3. *Ustawienia → Ogólne → VPN i zarządzanie urządzeniem* → zaufaj certyfikatowi.

> Darmowy Apple ID: działa **7 dni**, potem odświeżasz w AltStore (AltServer na
> tym samym Wi-Fi robi to automatycznie). Limit 3 apek, AltStore zajmuje jedną.

## 4. Użycie

1. Odpal RealCam, zezwól na mikrofon i sieć lokalną.
2. Wpisz **IP serwera** i port **8000** → **Połącz i nasłuchuj**.
3. W przeglądarce na PC widzisz miernik głośności na żywo.
4. **Zablokuj telefon / zgaś ekran** — nasłuch leci dalej w tle.

> **Przychodzące połączenie:** iOS na czas rozmowy przejmuje mikrofon (tego nie
> da się obejść), ale WebSocket z serwerem zostaje, a po odłożeniu słuchawki
> nasłuch **sam wraca** (z ponawianiem, bo system zwalnia mikrofon z opóźnieniem).

---

## Pomysły na dalej
- Nasłuch na żywo w przeglądarce (odtwarzanie PCM przez Web Audio).
- Zapis fragmentu do WAV, gdy przekroczony próg (dowód zdarzenia).
- Alert mailem / powiadomieniem push na PC.
- Kilka telefonów naraz (serwer już to uniesie).
- Dostęp spoza domu (VPN / tunel zamiast samego LAN).
