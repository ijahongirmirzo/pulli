# App Store listing (draft for App Store Connect)

For the App Store edition (bundle id `app.pulli.store`, photos and videos through Apple's
ImageCaptureCore). Character limits in brackets.

**Name** [30]: `Pulli - Phone Photos to Mac` (27)

**Subtitle** [30]: `Copy photos. Never start over.` (30)

**Category:** Utilities (secondary: Photography)

**Price:** Free

**Promotional text** [170]:
> Copy photos and videos from your phone to your Mac over USB. Pull the cable halfway?
> Pulli waits, then carries on from the exact byte where it stopped.

**Description** [4000]:
> Pulli copies the photos and videos on your phone to your Mac over a USB cable - and never
> loses progress. It works with Android phones that offer "Transferring images" over USB.
>
> Big copies take a while, and a lot can happen: the cable comes out, the phone locks, the Mac
> sleeps. Most tools start over. Pulli doesn't: it continues from where it stopped, even halfway
> through a 4 GB video, and checks every file.
>
> PLUG IN AND GO
> • No app to install on your phone. Plug it in, choose "Transferring images", and Pulli shows
>   what is on it.
> • See how many new photos there are since your last copy, and copy them in one click.
>
> COPIES THAT FINISH
> • Copies in checked blocks and records each one, so an interruption never costs more than a
>   few megabytes.
> • Cable pulled? Pulli waits for the same phone and carries on by itself - in any port.
> • Skips photos already on your Mac, even under another name.
>
> FITS IN ON YOUR MAC
> • Browse the phone's photos with previews and Quick Look.
> • Your phone in Finder's sidebar, under Locations.
> • Progress in the menu bar and in desktop widgets; notifications when a copy finishes.
> • Shortcuts actions, and a calm design in light and dark.
>
> PRIVATE
> • No account, no tracking, nothing collected. Clear History forgets your copies whenever you
>   like.
>
> Pulli is free and open source. A full edition that also copies documents, downloads and other
> folders is available from github.com/ijahongirmirzo/pulli.
>
> Requires a Mac with Apple silicon and macOS 26 or later, and a phone with a USB cable that
> carries data.

**Keywords** [100]: `phone,photos,transfer,usb,copy,import,camera,videos,backup,resume,ptp,pictures,media,cable` (90)

**Support URL:** https://github.com/ijahongirmirzo/pulli/issues

**Marketing URL:** https://github.com/ijahongirmirzo/pulli

**Privacy policy URL:** https://github.com/ijahongirmirzo/pulli/blob/main/docs/PRIVACY.md

**App Privacy (nutrition label):** Data Not Collected.

**Age rating:** 4+ (no objectionable content).

**Copyright:** 2026 Jahongirmirzo

**Notes for App Review:**
> Pulli needs an Android phone connected by USB. On the phone, choose "Transferring images"
> (PTP) in the USB notification; Pulli then lists its photos and videos and can copy them. If no
> phone is available, the app shows its setup guide. Pulli reads the phone through Apple's
> ImageCaptureCore framework, writes copies to Downloads › Pulli (or a folder the user picks),
> and reads the Pictures folder only to recognise photos that are already on the Mac. The local
> server on 127.0.0.1 lets the File Provider extension show the phone in Finder's sidebar.

**Screenshots:** 2880 × 1800 (16:10), made from the App Store edition's own screens:
phone ready → copying → reconnect and resume → copy complete → browse → menu bar and widgets.

## Review risk: naming another platform

App Review guideline 2.3.10 asks apps not to name other mobile platforms in their metadata. It is
mostly applied to iPhone apps, but to be safe the name, subtitle and keywords above avoid
"Android", and the description mentions it once, factually. If review objects, replace that
sentence with: "It works with phones that offer 'Transferring images' (PTP) over USB."
