# XR1710G: копия стока и OpenWrt с разметкой UBI 2.0 — из Windows одним скриптом

Скрипт для Gemtek XR1710G (Brightspeed XR1710G, Airoha AN7581, 512 МиБ SPI-NAND).
Он работает со стоковой прошивки до готового OpenWrt и всё делает сам:

1. останавливает стоковый загрузчик через UART и **снимает полную копию флеша**
   на ПК (все 512 МиБ со сверкой sha256), пока во флеш ещё ничего не записано;
2. размечает флеш сразу под **UBI 2.0** (`ubi` = `0x700000 + 0x1b700000`, резерв
   528 PEB под BMT вендорского загрузчика) и ставит OpenWrt;
3. пишет в слот `chainloader` **выбранный загрузчик** — U-Boot с HTTP-рекавери
   (YYH2913) или ванильный чейнлоадер U-Boot OpenWrt;
4. перезагружает роутер и проверяет, что OpenWrt поднялся с флеша.

Отдельно есть режимы «только копия» и «вернуть сток из копии».

> [!WARNING]
> **Полностью на железе скрипт ещё не прогонялся.** На XR1710G проверена
> первая половина: прерывание стокового загрузчика, TFTP из него, загрузка
> U-Boot OpenWrt и initramfs из ОЗУ, ключ SSH через консоль. Копия, разметка
> и запись загрузчика проверены на эмуляторе (`tests/`): стоковый U-Boot,
> U-Boot в ОЗУ, initramfs, настоящий TFTP и поддельный ssh — все сценарии,
> включая восстановление стока. Каждая
> команда, которую он даёт роутеру, взята из рабочих инструкций (ссылки в
> [Источниках](#источники-и-авторство)), но стоковый загрузчик AXON
> может ответить не так, как ожидается. В этом случае скрипт останавливается
> до записи и ничего не ломает: копия стока снимается первой, вендорский
> загрузчик (0x0–0x600000) не трогается никогда, а UART остаётся рабочим
> способом восстановления.

## Что нужно

* XR1710G на стоковой прошивке (или уже прошитый — тогда «копия» будет копией
  того, что стоит сейчас; скрипт об этом предупредит);
* USB-UART адаптер **3,3 В** (CH340, CP2102, FT232, PL2303) с драйвером;
* отвёртка Torx T10, Ethernet-кабель;
* Windows 10/11, PowerShell 5.1 (есть в системе), **клиент OpenSSH**
  (Параметры → Система → Дополнительные компоненты; в Windows 11 обычно уже
  стоит), права администратора;
* ~600 МБ свободного места под копию.

## Подключение

1. Под наклейкой с QR-кодом винт Torx T10. Выкрутить, затем развести серую и
   белую половины корпуса, начиная со стороны портов — защёлки по всему периметру.
2. Разъём UART рядом с винтом, считая от винта: **TX – GND – VCC – N/C – RX**,
   115200 8N1. Подключить GND, TX роутера → RX адаптера, RX роутера → TX
   адаптера. **VCC не подключать.**
3. Ethernet от ПК — в **гигабитный LAN-порт** роутера. Сетевой драйвер стокового
   загрузчика капризный: если TFTP не идёт, скрипт повторит, а переткнуть кабель
   в другой порт можно прямо во время повторов.

Адрес `192.168.1.10/24` на этом адаптере скрипт задаст сам (и вернёт DHCP в
конце), так же как и временное правило брандмауэра для TFTP (UDP 69).

## Какой загрузчик выбрать

Стоковый загрузчик (U-Boot 2014.04 «AXON 1.6», подписанный) остаётся на месте и
грузит то, что лежит в слоте `chainloader` (0x600000, 1 МиБ). Туда ставится один
из двух вариантов; обе сборки работают с разметкой UBI 2.0.

| | **http-uboot** (YYH2913, `xr1710g_260805`) — по умолчанию | **U-Boot OpenWrt** (`uboot-airoha`, ванильный) |
|---|---|---|
| Версия | U-Boot 2026.07, сторонняя сборка | U-Boot 2026.01 из OpenWrt, конфигурация Gemtek W1700K |
| Рекавери | веб-страница `http://192.168.255.1`, свой DHCP; заливка `sysupgrade.itb` и самого загрузчика из браузера | меню в UART: TFTP, recovery из флеша, установщик по TFTP |
| Как войти в рекавери | кабель в порт **10GbE**, держать **reset** при включении, отпустить, когда индикатор сменит красный на «бегущий» | только UART (USB-UART + TFTP-сервер на ПК) |
| Нужен ли UART после установки | нет | да, для любого восстановления |
| Сеть в загрузчике | 10GbE | гигабитные порты |
| Пересоздание UBI | из веб-интерфейса, с выбором раскладки 2.0 / 1.5 / 1.0 и восстановлением factory из DSD | вручную из initramfs |
| Окружение AXON | не меняется: слот «двухвходовый», работает со стоковым `bootcmd` | `bootcmd` меняется на `flash read 0x600000 0x100000 $loadaddr; bootm` (как в инструкции OpenWrt) |
| Происхождение | бинарник из релиза автора, исходники в [YYH2913/http-uboot](https://github.com/YYH2913/http-uboot) | собран из [akorshun/openwrt `xr1710g-r2`](https://github.com/akorshun/openwrt/releases/tag/xr1710g-r2) |

Оба варианта загружают OpenWrt из тома `fit`, обновления ставятся обычным
`sysupgrade`. Если сомневаетесь — берите **http-uboot**: без UART его можно
восстановить из браузера. Сменить загрузчик позже можно его же веб-страницей
(http-uboot) или повторным запуском скрипта.

## Запуск

Скачать репозиторий (Code → Download ZIP или `git clone`), распаковать, затем
**двойной щелчок по `xr1710g-flash.cmd`** — или из PowerShell:

```powershell
.\xr1710g-flash.ps1                              # установка, всё спросит
.\xr1710g-flash.ps1 -ComPort COM5 -Loader http   # без вопросов о порте и загрузчике
.\xr1710g-flash.ps1 -Mode Backup                 # только копия стока, флеш не трогается
.\xr1710g-flash.ps1 -Mode Restore -BackupDir .\backup\20261028-150000
.\xr1710g-flash.ps1 -Firmware D:\my-sysupgrade.itb   # своя сборка OpenWrt
```

Скрипт сам попросит права администратора. Дальше:

1. спросит COM-порт и загрузчик (если не заданы параметрами);
2. попросит **включить питание** роутера — сам прервёт автозагрузку;
3. снимет копию (несколько минут), покажет серийный номер и MAC-адреса;
4. **спросит подтверждение** (`YES`) перед первой записью во флеш;
5. разметит UBI, поставит OpenWrt, перезагрузится, запишет загрузчик, ещё раз
   перезагрузится и дождётся OpenWrt.

Всего ~10–15 минут. Весь вывод консоли роутера пишется в `serial.log`, шаги
скрипта — в `flash.log`, оба лежат в папке копии.

### Что происходит внутри

| Шаг | Где выполняется | Запись во флеш |
|---|---|---|
| Прерывание стокового U-Boot, `printenv` → `stock-uboot-env.txt` | AXON U-Boot | нет |
| TFTP `chainload-uboot.itb` в ОЗУ, `bootm` | AXON U-Boot | нет |
| TFTP `xr1710g-backup-initramfs.itb` в ОЗУ, `bootm` | U-Boot OpenWrt в ОЗУ | нет |
| SSH-ключ через консоль, копия `mtd0…mtd3` по SSH со сверкой sha256 | initramfs в ОЗУ | нет |
| Сборка тома `factory` из `mtd0-vendor.bin` | ПК | нет |
| `ubiformat` области `ubi`, тома, OpenWrt, чтение обратно | initramfs в ОЗУ | **да** (0x700000–0x1be00000) |
| TFTP загрузчика, `flash erase/write 0x600000`, сверка `cmp.b` | AXON U-Boot | **да** (0x600000–0x700000) |
| `setenv bootcmd …; saveenv` — только для U-Boot OpenWrt | AXON U-Boot | окружение AXON |
| `reset`, ожидание OpenWrt, проверка `board_name` | — | нет |

`xr1710g-backup-initramfs.itb` — это `initramfs-recovery.itb` из той же сборки
OpenWrt с двумя изменениями в DTB (см. `tools/make-backup-initramfs.py`,
изменяется 39 байт, размеры не меняются, хеши FIT пересчитаны):

* у раздела `ubi` убран `compatible = "linux,ubi"`, чтобы ядро не пыталось
  подключить UBI поверх стоковых данных до того, как с них снята копия;
* у MAC-узлов Ethernet (`gdm1`, `gdm2`, `gdm4`) отключены `nvmem-cells`: они
  ссылаются на том `factory` в UBI, которого на стоке нет, и без этого драйвер
  Ethernet бесконечно ждёт его (deferred probe) и сети в initramfs нет —
  именно так было при первом запуске на железе. Без них MAC случайный.

Кроме того, ядро OpenWrt подключает раздел с
именем `ubi` само, если он начинается с `UBI#` (патч 490). На стоке там лежит
банк `tclinux` и этого не происходит. Если роутер уже прошивали, скрипт
предупредит, что копия будет не стоковой, и отключит UBI (`ubidetach`) перед
копией и перед восстановлением.

Стоковый `bootcmd` бывает разным: в README http-uboot это
`flash read 0x602100 0x4000000 $loadaddr; bootm`, а на одном из наших XR1710G
с тем же AXON 1.6 — `flash imgread 2048;bootm`. Для http-uboot скрипт оставляет
только формы, которые его автор указал как рабочие, а любую другую заменяет на
`flash read 0x602100 0x4000000 $loadaddr; bootm`. Исходное значение сохраняется
в `stock-uboot-env.txt` и возвращается режимом Restore.

Слот пишется **командой стокового загрузчика** `flash write`, как в инструкции
OpenWrt для W1700K: этот загрузчик читает слот через свою таблицу BMT, и только
его собственная запись гарантированно ляжет туда, откуда он потом читает.

## Копия стока

Папка `backup\<дата-время>\`:

| Файл | Что это |
|---|---|
| `mtd0-vendor.bin` | 6 МиБ: загрузчик AXON, его окружение, DSD (MAC, серийный номер), EEPROM Wi-Fi |
| `mtd1-chainloader.bin` | 1 МиБ: начало стокового банка `tclinux` |
| `mtd2-ubi.bin` | 439 МиБ: стоковые банки прошивки и данные |
| `mtd3-reserved_bmt.bin` | 66 МиБ: хвост флеша с таблицами BMT вендора |
| `SHA256SUMS` | суммы, сверенные с флешем на роутере |
| `stock-uboot-env.txt` | `printenv` стокового загрузчика |
| `factory.bin` | собранный том `factory` (EEPROM + MAC + fan_id + серийный номер) |
| `router-info.txt`, `flash.log`, `serial.log` | `/proc/mtd`, плохие блоки, журналы |

Копия снимается из Linux «как есть» (данные после ECC, без OOB). Сохраните
папку отдельно — это единственный способ вернуть сток.

### Вернуть сток

```powershell
.\xr1710g-flash.ps1 -Mode Restore -BackupDir .\backup\20261028-150000
```

Скрипт снова загрузит initramfs в ОЗУ, запишет `mtd2-ubi.bin` в область `ubi`
(`mtd write`), затем стоковым загрузчиком вернёт `mtd1-chainloader.bin` в слот и
`bootcmd` из `stock-uboot-env.txt`. Если с момента копии во флеше появились
новые плохие блоки, побайтного совпадения не будет — скрипт предупредит.

## Разметка UBI 2.0

| Раздел | Смещение | Размер | |
|---|---|---|---|
| `vendor` | `0x00000000` | `0x00600000` | загрузчик AXON, `uenv`, `dsd` — не трогается |
| `chainloader` | `0x00600000` | `0x00100000` | http-uboot или U-Boot OpenWrt |
| `ubi` | `0x00700000` | `0x1b700000` | UBI, конец `0x1be00000` |
| `reserved_bmt` | `0x1be00000` | `0x04200000` | 528 PEB под BMT вендора — не трогается |

Тома UBI (как в установщике hurrian): `0 ubootenv`, `1 ubootenv2`,
`2 factory` (static, 64 КиБ: EEPROM @0, WAN MAC @0x5000, LAN MAC @0x6000,
fan_id @0x7000, серийный номер @0x8000), `3 recovery` (initramfs OpenWrt),
`fit` и `rootfs_data` — их создаёт `nand_upgrade_fit` из OpenWrt.

Образ, который вы ставите (в том числе потом через рекавери http-uboot),
должен быть собран с той же разметкой: в DTB внутри FIT
`ubi` = `<0x00700000 0x1b700000>`. Скрипт проверяет это для `-Firmware` и
отказывается ставить образы UBI 1.5 (`0x1d9c0000`) и UBI 1.0 (`0x1f700000`).
В веб-рекавери http-uboot для таких образов выбирайте **UBI 2.0**.

## После установки

* OpenWrt: `http://192.168.1.1`, `root` без пароля — задайте пароль.
* Обновления: `sysupgrade` с `*-gemtek_xr1710g-ubi-squashfs-sysupgrade.itb`.
* Рекавери http-uboot: ПК в порт 10GbE с DHCP, reset при включении,
  `http://192.168.255.1`, цель `firmware`, раскладка `UBI 2.0`.
* Рекавери U-Boot OpenWrt: UART, меню загрузчика, «Boot system via TFTP»
  (ПК `192.168.1.10`, файл
  `openwrt-airoha-an7581-gemtek_xr1710g-ubi-initramfs-recovery.itb`) или
  «Boot recovery system from flash».

## Если что-то пошло не так

* **«стоковый U-Boot так и не появился»** — проверьте COM-порт, GND, TX/RX
  (часто перепутаны), что адаптер на 3,3 В.
* **«не удалось остановить загрузку»** — скрипт попросит передёрнуть питание и
  попробует снова.
* **TFTP не идёт** — кабель в другой LAN-порт; в `flash.log` видно состояние
  TFTP-сервера. Сторонние брандмауэры (не Windows) нужно открыть для UDP 69.
* **Ошибка до шага «Разметка UBI 2.0»** — во флеш ничего не записано, сток
  загрузится как обычно, можно запускать заново.
* **Ошибка после разметки, до записи загрузчика** — сток уже стёрт, но
  вендорский загрузчик цел: просто запустите скрипт ещё раз (он снимет
  «копию» уже размеченного флеша в новую папку — первую копию не трогает).
* **OpenWrt не загрузился после записи загрузчика** — `serial.log`. С
  http-uboot роутер сам уйдёт в веб-рекавери, если не найдёт `fit`.

Ручной путь, по которому идёт скрипт, — команды стокового загрузчика из
[инструкции OpenWrt](https://github.com/openwrt/openwrt/pull/22397):

```
setenv serverip 192.168.1.10 ; setenv ipaddr 192.168.1.1
tftpboot 0x89000000 openwrt-airoha-an7581-gemtek_xr1710g-ubi-chainload-uboot.itb
setenv one flash read 0x600000 0x100000 \$loadaddr
setenv two "; bootm"
setenv bootcmd "$one$two"
saveenv
flash erase 0x600000 0x100000
flash write 0x600000 0x100000 0x89000000
reset
```

## Файлы

| Файл | Откуда | sha256 |
|---|---|---|
| `xr1710g-flash.ps1`, `xr1710g-flash.cmd` | этот репозиторий | |
| `router/install-ubi.sh` | этот репозиторий; порядок и размеры томов, сборка `factory` — из `install.sh` [hurrian/w1700k-ubi-installer](https://github.com/hurrian/w1700k-ubi-installer/blob/46df1f5282f53c6757752354d7b6702f6fa54ec5/files/installer/install.sh) | |
| `firmware/xr1710g-chainloader-slot.bin` | [YYH2913/http-uboot, релиз `xr1710g_260805`](https://github.com/YYH2913/http-uboot/releases/tag/xr1710g_260805) | `deaefed3…d27be30` |
| `firmware/openwrt-…-chainload-uboot.itb` | [akorshun/openwrt, релиз `xr1710g-r2`](https://github.com/akorshun/openwrt/releases/tag/xr1710g-r2) (коммит `ce11b1a79a`) | `1425540d…5dd3d9` |
| `firmware/openwrt-…-initramfs-recovery.itb` | там же | `51acb98d…eedf3b` |
| `firmware/openwrt-…-squashfs-sysupgrade.itb` | там же | `23ef354d…84523f` |
| `firmware/xr1710g-backup-initramfs.itb` | `tools/make-backup-initramfs.py` из `initramfs-recovery.itb` | `dbf1b9f1…005758` |

Полные суммы — в `firmware/SHA256SUMS`, скрипт сверяет их при каждом запуске.

Сборка OpenWrt `xr1710g-r2` — ветка `main-gemtek-xr1710g` (OpenWrt main,
ядро 6.18.55, поддержка XR1710G на модели W1700K и исправления 10G-линков),
на железе она пока не проверялась так же, как и скрипт. Через `-Firmware`
можно поставить любую другую сборку под `gemtek,xr1710g-ubi` с UBI 2.0.

## Источники и авторство

* **Способ установки через чейнлоадер** (слот 0x600000, `flash write`
  стокового загрузчика, `bootcmd` через `one`/`two`, вскрытие и распиновка
  UART) — коммит OpenWrt «airoha: add support for Gemtek W1700K»,
  Andrew LaMarche, в OpenWrt внесён Christian Marangi:
  [openwrt/openwrt#17869, 9930758](https://github.com/openwrt/openwrt/pull/17869/changes/99307582dea256731a8006a734a41ac6f26be5b7).
* **Поддержка XR1710G** и чейнлоадер для него — Kenneth Kasilag (hurrian),
  [openwrt/openwrt#22397](https://github.com/openwrt/openwrt/pull/22397);
  на этом основана ветка `main-gemtek-xr1710g`, из которой собраны образы.
* **Установщик UBI**: тома `ubootenv`/`ubootenv2`/`factory`/`recovery`/`fit`,
  поиск EEPROM (магия `7990` с 0x405000), поля DSD `wan_mac`, `lan_mac`,
  `fan_id`, `serial_number` и раскладка тома `factory` —
  [hurrian/w1700k-ubi-installer](https://github.com/hurrian/w1700k-ubi-installer)
  (GPL-3.0), который в свою очередь основан на
  [dangowrt/owrt-ubi-installer](https://github.com/dangowrt/owrt-ubi-installer)
  (Daniel Golle).
* **Разметка UBI 2.0** (`0x1b700000`, резерв 528 PEB), «двухвходовый» слот
  (шим `27 05 19 56` на 0x600000, FIT на 0x602100), совместимые формы
  `bootcmd`, HTTP-рекавери и загрузчик `xr1710g-chainloader-slot.bin` —
  [YYH2913/http-uboot](https://github.com/YYH2913/http-uboot).
* Сам скрипт, TFTP-сервер, сборка `factory` на ПК, initramfs для копии,
  режимы копии и восстановления, эмулятор для тестов — этот репозиторий
  (Andrey Korshunov). Слот http-uboot ранее проверен на железе в
  [akorshun/xr1710g-uboot-recovery](https://github.com/akorshun/xr1710g-uboot-recovery).

## Лицензия

Скрипты — GPL-3.0 (`LICENSE`): `router/install-ubi.sh` и сборка `factory`
в `xr1710g-flash.ps1` повторяют логику GPL-3.0 установщика hurrian.
Бинарные образы в `firmware/` распространяются на условиях их проектов
(OpenWrt и U-Boot — GPL-2.0); исходный код — по ссылкам в таблице выше.

## Тесты

```powershell
.\tests\run-fake.ps1          # сквозной прогон на эмуляторе: Backup, Install x2, Restore, отказ UBI 1.0
```

```sh
sh tests/test-install-ubi.sh  # install-ubi.sh с заглушками ubi-utils
python tools/make-backup-initramfs.py --check firmware/xr1710g-backup-initramfs.itb
```

Всё это же запускает CI (`.github/workflows/check.yml`).
