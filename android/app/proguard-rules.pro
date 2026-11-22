# Estä varoitukset androidx.window-laajennuksista, joita ei käytetä
-dontwarn androidx.window.**
-dontwarn androidx.window.extensions.**
-dontwarn androidx.window.sidecar.**

# PDFBox Android ja valinnaiset kuvadekooderit (JP2Decoder / JP2Encoder jne.)
-dontwarn com.gemalto.jp2.**
-dontwarn org.apache.harmony.javax.security.auth.x500.**
-dontwarn org.bouncycastle.**

# Säilytetään PDFBox- ja juniversalchardet-luokat R8-kutistukselta
-keep class com.tom_roush.pdfbox.** { *; }
-keep class org.mozilla.universalchardet.** { *; }
-keep class com.metait.fepubreader.PdfMetadataFixer { *; }
