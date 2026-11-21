package com.metait.fepubreader

import android.content.Context
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.cos.COSDictionary
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.cos.COSString
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDDocumentInformation
import org.mozilla.universalchardet.UniversalDetector
import java.io.File
import java.nio.charset.Charset
import java.nio.charset.StandardCharsets

object PdfMetadataFixer {

    private var initialized = false

    fun init(context: Context) {
        if (!initialized) {
            PDFBoxResourceLoader.init(context)
            initialized = true
        }
    }

    /**
     * Tunnistaa raakatavujen merkistön juniversalchardet-kirjaston avulla.
     * Jos teksti on liian lyhyt tilastolliseen tunnistukseen tai tunnistus epäonnistuu,
     * sovelletaan suomalaisille ja pohjoismaisille teksteille optimaalista varamekanismia
     * (UTF-8 tarkistus -> Windows-1252 / ISO-8859-1).
     */
    fun tunnistaJaDekoodaa(rawBytes: ByteArray?): Pair<String, String>? {
        if (rawBytes == null || rawBytes.isEmpty()) return null

        // 1. Tarkistetaan alkaako teksti UTF-16BE BOM:lla (FE FF)
        if (rawBytes.size >= 2 && rawBytes[0] == 0xFE.toByte() && rawBytes[1] == 0xFF.toByte()) {
            val text = String(rawBytes, 2, rawBytes.size - 2, StandardCharsets.UTF_16BE)
            return Pair(siistiTeksti(text), "UTF-16BE")
        }

        // 2. Tarkistetaan alkaako teksti UTF-8 BOM:lla (EF BB BF)
        if (rawBytes.size >= 3 &&
            rawBytes[0] == 0xEF.toByte() &&
            rawBytes[1] == 0xBB.toByte() &&
            rawBytes[2] == 0xBF.toByte()
        ) {
            val text = String(rawBytes, 3, rawBytes.size - 3, StandardCharsets.UTF_8)
            return Pair(siistiTeksti(text), "UTF-8")
        }

        // 3. Tarkistetaan onko teksti UTF-16BE ilman BOM:ia (vuorotellen nollatavut)
        if (rawBytes.size >= 4 &&
            ((rawBytes[0] == 0.toByte() && rawBytes[2] == 0.toByte()) ||
             (rawBytes[1] == 0.toByte() && rawBytes[3] == 0.toByte()))
        ) {
            val isBE = rawBytes[0] == 0.toByte()
            val charset = if (isBE) StandardCharsets.UTF_16BE else StandardCharsets.UTF_16LE
            val text = String(rawBytes, charset)
            return Pair(siistiTeksti(text), charset.name())
        }

        // 4. Käytetään juniversalchardet UniversalDetector -kirjastoa
        val detector = UniversalDetector(null)
        detector.handleData(rawBytes, 0, rawBytes.size)
        detector.dataEnd()
        val detectedCharsetName = detector.detectedCharset
        detector.reset()

        if (detectedCharsetName != null) {
            try {
                val charset = Charset.forName(detectedCharsetName)
                val text = String(rawBytes, charset)
                return Pair(siistiTeksti(text), detectedCharsetName)
            } catch (_: Exception) {}
        }

        // 5. Varavaihtoehdot lyhyille teksteille (UniversalDetector vaatii usein 20-50 tavua):
        // Yritetään ensin validia UTF-8:aa
        try {
            val utf8Decoder = StandardCharsets.UTF_8.newDecoder()
            val byteBuffer = java.nio.ByteBuffer.wrap(rawBytes)
            val charBuffer = utf8Decoder.decode(byteBuffer)
            val text = charBuffer.toString()
            return Pair(siistiTeksti(text), "UTF-8 (fallback)")
        } catch (_: Exception) {}

        // Yritetään Windows-1252 / ISO-8859-1 (suomalaisille PDF-tiedostoille erittäin yleinen)
        try {
            val win1252 = Charset.forName("windows-1252")
            val text = String(rawBytes, win1252)
            return Pair(siistiTeksti(text), "WINDOWS-1252 (fallback)")
        } catch (_: Exception) {}

        return Pair(siistiTeksti(String(rawBytes, StandardCharsets.ISO_8859_1)), "ISO-8859-1")
    }

    private fun siistiTeksti(text: String): String {
        return text.replace("\u0000", "")
            .replace(Regex("""\s+"""), " ")
            .trim()
    }

    /**
     * Suorittaa PDFBox- ja juniversalchardet-metatiedon erikoiskyselyn ja korjauksen:
     * - Lukee raakatavut suoraan COSDictionarysta (COSName.TITLE, COSName.AUTHOR jne.)
     * - Päättelee merkistön juniversalchardetilla
     * - Dekoodaa tiedot oikeaan merkistöön
     * - Jos [tallennaTakaisinPdfTiedostoon] on tosi, kirjoittaa korjatut tiedot
     *   takaisin PDDocumentInformation-olioon ja tallentaa PDF-tiedoston
     *   standardissa UTF-16BE muodossa.
     */
    fun suoritaMetaErikoiskysely(
        context: Context,
        tiedostoPolku: String,
        tallennaTakaisinPdfTiedostoon: Boolean = false
    ): Map<String, Any?> {
        init(context)

        val file = File(tiedostoPolku)
        if (!file.exists() || !file.canRead()) {
            return mapOf(
                "success" to false,
                "error" to "Tiedostoa ei löydy tai sitä ei voi lukea: $tiedostoPolku"
            )
        }

        var document: PDDocument? = null
        try {
            document = PDDocument.load(file)
            val info: PDDocumentInformation = document.documentInformation ?: PDDocumentInformation()
            val cosDict: COSDictionary = info.cosObject

            var detectedTitle: String? = null
            var detectedAuthor: String? = null
            var detectedPublisher: String? = null
            var detectedKeywords: String? = null
            var usedCharset: String? = null

            // 1. Otsikko (COSName.TITLE)
            val titleItem = cosDict.getItem(COSName.TITLE)
            if (titleItem is COSString) {
                val pair = tunnistaJaDekoodaa(titleItem.bytes)
                if (pair != null) {
                    detectedTitle = pair.first
                    usedCharset = pair.second
                }
            }

            // 2. Kirjailija (COSName.AUTHOR)
            val authorItem = cosDict.getItem(COSName.AUTHOR)
            if (authorItem is COSString) {
                val pair = tunnistaJaDekoodaa(authorItem.bytes)
                if (pair != null) {
                    detectedAuthor = pair.first
                    if (usedCharset == null) usedCharset = pair.second
                }
            }

            // 3. Kustantaja / Luoja (COSName.CREATOR tai COSName.PRODUCER)
            val creatorItem = cosDict.getItem(COSName.CREATOR) ?: cosDict.getItem(COSName.PRODUCER)
            if (creatorItem is COSString) {
                val pair = tunnistaJaDekoodaa(creatorItem.bytes)
                if (pair != null) {
                    detectedPublisher = pair.first
                    if (usedCharset == null) usedCharset = pair.second
                }
            }

            // 4. Avainsanat (COSName.KEYWORDS)
            val kwItem = cosDict.getItem(COSName.KEYWORDS)
            if (kwItem is COSString) {
                val pair = tunnistaJaDekoodaa(kwItem.bytes)
                if (pair != null) {
                    detectedKeywords = pair.first
                }
            }

            // 5. Julkaisuvuosi / Päivämäärä
            var publishYear = 0
            var publishDateText: String? = null
            try {
                val cal = info.creationDate
                if (cal != null) {
                    publishYear = cal.get(java.util.Calendar.YEAR)
                    publishDateText = publishYear.toString()
                }
            } catch (_: Exception) {}

            var tallennettuPdfään = false
            if (tallennaTakaisinPdfTiedostoon) {
                try {
                    var muuttunut = false
                    if (!detectedTitle.isNullOrEmpty()) {
                        info.title = detectedTitle
                        muuttunut = true
                    }
                    if (!detectedAuthor.isNullOrEmpty()) {
                        info.author = detectedAuthor
                        muuttunut = true
                    }
                    if (!detectedPublisher.isNullOrEmpty()) {
                        info.creator = detectedPublisher
                        muuttunut = true
                    }
                    if (!detectedKeywords.isNullOrEmpty()) {
                        info.keywords = detectedKeywords
                        muuttunut = true
                    }

                    if (muuttunut) {
                        document.documentInformation = info
                        document.save(file)
                        tallennettuPdfään = true
                    }
                } catch (_: Exception) {}
            }

            val tagsList = detectedKeywords?.split(Regex("""[,;]"""))
                ?.map { it.trim() }
                ?.filter { it.isNotEmpty() }
                ?: emptyList()

            return mapOf(
                "success" to true,
                "title" to (detectedTitle ?: ""),
                "author" to (detectedAuthor ?: ""),
                "publisher" to (detectedPublisher ?: ""),
                "publishDateText" to (publishDateText ?: ""),
                "publishYear" to publishYear,
                "tags" to tagsList,
                "detectedCharset" to (usedCharset ?: "Tuntematon"),
                "savedToPdf" to tallennettuPdfään
            )
        } catch (e: Exception) {
            return mapOf(
                "success" to false,
                "error" to (e.message ?: "Tuntematon virhe PDFBox-käsittelyssä")
            )
        } finally {
            try {
                document?.close()
            } catch (_: Exception) {}
        }
    }
}
