# Automatic DMG releases

Workflow [Release DMG](.github/workflows/release.yml) berjalan setiap ada push ke
`main`, termasuk merge pull request. Setiap run yang berhasil membuat GitHub
Release baru dengan tag `build-<run number>.<attempt>` dan satu file
`simpleMacEq-build-<run number>.<attempt>-universal.dmg`.

DMG berisi aplikasi universal (Apple Silicon + Intel) untuk macOS 14.4 ke atas
dan shortcut Applications untuk instalasi drag-and-drop. Tag menunjuk ke commit
yang dibuild. Menjalankan ulang workflow membuat tag baru agar tidak menimpa
release sebelumnya. Versi aplikasi mengikuti `MARKETING_VERSION` di project
Xcode; build number mengikuti nomor run GitHub Actions.

## Mengaktifkan

1. Commit dan push `.github/workflows/release.yml` dan file panduan ini ke `main`.
2. Pastikan GitHub Actions diizinkan di **Settings → Actions → General**,
   termasuk action `actions/checkout` jika repository membatasi action.
3. Buka **Actions → Release DMG** untuk melihat proses build. Setelah berhasil,
   unduh `.dmg` dari tab **Releases** repository.

Tidak perlu menambahkan PAT atau secret sendiri. Workflow memakai
`GITHUB_TOKEN` bawaan dengan `contents: write` untuk membuat tag, release,
dan mengunggah DMG. Kebijakan organisasi dan ruleset tag tetap harus mengizinkan
operasi tersebut. Lihat [dokumentasi token GitHub Actions](https://docs.github.com/en/actions/tutorials/authenticate-with-github_token).

Untuk menjalankan manual, pilih **Actions → Release DMG → Run workflow** dan
branch `main`. Branch lain dilewati. Satu push berisi beberapa commit menghasilkan
satu release dari commit terakhir pada push tersebut.

## Signing dan validasi

Build memakai ad-hoc signing, sehingga tidak memerlukan akun Apple Developer.
Aplikasi belum notarized oleh Apple dan bisa diblokir Gatekeeper saat dibuka.
Distribusi dengan identitas developer terverifikasi memerlukan sertifikat
**Developer ID Application** dan proses notarization; keduanya belum dikonfigurasi.

Sebelum publikasi, workflow memastikan binary berisi arsitektur `arm64` dan
`x86_64`, memverifikasi code signature, dan memeriksa integritas DMG. Pemeriksaan
ini tidak menguji playback audio atau izin capture pada komputer pengguna.
Release dibuat memakai [GitHub CLI](https://cli.github.com/manual/gh_release_create).
