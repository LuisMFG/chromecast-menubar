# Engenharia reversa com REA — Chromecast (1ª geração)

## Aparelho

Lido ao vivo na rede local (`/setup/eureka_info` na porta 8008 e pelo canal `setup` do Cast):

| | |
|---|---|
| Modelo | Chromecast (Google Inc.), produto `chorizo` |
| Firmware | `1.56.467165`, stable-channel, sem atualização pendente |
| Portas | 8008 (HTTP, sem autenticação) · 8009 (Cast v2, TLS com certificado autoassinado) |
| Capacidades | `reboot_supported`, `renaming_supported`, `multizone_supported`, `opencast_supported`, `setup_supported`… |

## Cast v2 (porta 8009)

TLS + mensagens `CastMessage` em protobuf com prefixo de 4 bytes. Namespaces usados pelo app:

| Namespace | Uso |
|---|---|
| `urn:x-cast:com.google.cast.tp.connection` | `CONNECT` com `receiver-0` e com o `transportId` do app |
| `urn:x-cast:com.google.cast.tp.heartbeat` | `PING`/`PONG` a cada 5 s |
| `urn:x-cast:com.google.cast.receiver` | `GET_STATUS`, `SET_VOLUME` (`level`/`muted`), `STOP` |
| `urn:x-cast:com.google.cast.media` | `GET_STATUS`, `PLAY`, `PAUSE`, `SEEK` |
| `urn:x-cast:com.google.cast.setup` | API local de configuração (abaixo) |

Observado ao vivo: com nada transmitindo, o app ativo é `E8C28D3C` "Backdrop" (`isIdleScreen: true`).
O volume é `attenuation` em passos de `0.05`.

## App Google Home 4.31.27 (Android) com REA

Alvo: `com.google.android.apps.chromecast.app_4.31.27.5` (`.apkm` do APKMirror).
- `rea extract-artifact` no `.apkm` → `base.apk` (sha256 `2179b747…13a7d4`) + splits de idioma/ABI.
- `rea identify-flutter-build` → **não é Flutter** (Android nativo; lógica em `classes*.dex`).
- `rea extract-artifact` no `base.apk` foi recusado de propósito: o APK tem recursos ofuscados que só
  diferem em caixa (`res/-Fs.xml` vs `res/-FS.xml`), e o APFS não guarda os dois. Os 7 `classes*.dex`
  foram extraídos à parte e varridos por strings.

### O que o código revelou

- O Google Home **não chama mais a API HTTP da porta 8008**: ele tunela as mesmas rotas por dentro do Cast,
  no namespace **`urn:x-cast:com.google.cast.setup`**, com rótulos `CAST_V2_LOCAL_` / `CAST_V2_CLOUD_` e um
  `cast_local_authorization_token`.
- Tabela de rotas ao lado do namespace: `eureka_info`, `set_eureka_info`, `reboot`, `forget_wifi`,
  `supported_timezones`, `supported_locales`, `get_app_device_id`, `multizone/join_group`,
  `multizone/leave_group`, `multizone/disband_group`, `multizone/set_audio_output_delay`,
  `user_eq/set_equalizer`, `ultrasound/enable`, `assistant/*`.
- `E8C28D3C` aparece junto de "Failed to connect to the backdrop app" — o mesmo appId visto ao vivo.

### Formato confirmado no aparelho (só leituras)

```json
→ {"type": "eureka_info", "request_id": 21, "data": {}}
← {"type": "eureka_info", "request_id": 21, "response_code": 200, "response_string": "OK", "data": {...}}
```

| Tentativa | Resultado |
|---|---|
| `data: {}` | 200, `eureka_info` completo |
| `data: {"params": ["build_info", "device_info"]}` | 200, só os grupos pedidos |
| `data: {"params": "name,build_info"}` (texto) | 200, `data` vazio |
| `request_type` no lugar de `type` | 400 Bad Request |
| `supported_timezones` | 200, lista de fusos em pt-BR |

No firmware 1.56 o canal responde **sem** `cast_local_authorization_token`.

### Usado no app, não testado aqui

`set_eureka_info {"name": …}` (renomear) e `reboot {"params": "now"}` (reiniciar) seguem o mesmo formato;
não foram executados durante a análise porque alteram o aparelho.
