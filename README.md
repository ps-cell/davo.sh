# davo.sh

Discord filesharing sucks, I don't have dropbox and I don't trust _any_ of these ppl anyways.

`davo.sh` is a slim little file-transfer tool for exactly that situation and reason. No account, no recipient-side installation, and no need to hand somebody a crypto tutorial before sending them a file.

```bash
./davo.sh send photo.jpg
```

The file is encrypted locally before upload. `davo.sh` gives you a link and a passphrase; the recipient can decrypt the file in their browser without installing anything.

The plaintext and passphrase are never uploaded.

## Requirements

### Linux / macOS

- `bash`
- `curl`
- `gpg`
- `zip` (for directories)

### Windows

- PowerShell 5.1+
- GnuPG

[Gpg4win](https://gpg4win.org/) includes GnuPG. With `winget`:

```powershell
winget install --id GnuPG.GnuPG --exact
```

Use the standalone `davo.cmd`. Syntax is the same as for `davo.sh`.

## Usage

```bash
./davo.sh send photo.jpg
./davo.sh send folder/ -e 24h
./davo.sh get 'https://...'
./davo.sh encrypt photo.jpg
./davo.sh decrypt photo.jpg.gpg
```

`get` accepts both `davo.sh` HTML links and raw encrypted links.

`encrypt` and `decrypt` are thin GnuPG wrappers.

Use `--no-html` with `send` to upload raw encrypted OpenPGP instead of generating the browser decryptor.

**Uploads expire after 1 hour by default.** Use `--expiry 24h` (or `-e 24h`) to change the expiry.

## Backends

BobaShare is the default backend. `auto` tries BobaShare first and falls back to qurl.sh.

```bash
./davo.sh send photo.jpg --backend bobashare
./davo.sh send photo.jpg --backend qurl
```

BobaShare supports uploads up to 1 GiB and expiries up to 30 days. qurl.sh supports uploads up to 500 MiB and expiries up to 7 days.

## Archives

Directories are zipped before encryption. Regular files are only zipped when they are larger than 10 MiB.

## Passwords

Passphrases are visible while typing. Generated passwords are normally three Diceware words from the EFF 7776-word list, with a 32-character random hexadecimal fallback.

## Encryption

OpenPGP encryption uses AES-256 with iterated+salted SHA-256 S2K. Compression is disabled.

The browser decryptor embeds OpenPGP.js 6.3.1.

![Browser decryptor](img/decrypt-html.png)
