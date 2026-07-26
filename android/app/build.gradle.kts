import java.security.KeyStore
import java.util.Base64

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// CI signing: the keystore is passed in as base64 through KEYSTORE_BASE64.
// An *unset* secret still reaches Gradle as an empty string, so blank must be
// treated exactly like "no CI keystore" — otherwise we write a 0-byte file and
// AGP fails deep inside the DER parser ("Tag number over 30 is not supported")
// with no hint about the real cause.
val ciKeystoreBase64: String? =
    System.getenv("KEYSTORE_BASE64")?.filterNot { it.isWhitespace() }?.ifEmpty { null }
val ciStorePassword: String = System.getenv("KEYSTORE_PASSWORD") ?: "android"
val ciKeyAlias: String = System.getenv("KEY_ALIAS") ?: "debug-key"

fun decodeCiKeystore(base64: String): ByteArray {
    val bytes = try {
        Base64.getMimeDecoder().decode(base64)
    } catch (e: IllegalArgumentException) {
        throw GradleException(
            "KEYSTORE_BASE64 is not valid base64 (${e.message}). Re-create the secret with:\n" +
                "  [Convert]::ToBase64String([IO.File]::ReadAllBytes(\"debug-key.keystore\")) | Set-Clipboard",
        )
    }
    if (bytes.isEmpty()) {
        throw GradleException("KEYSTORE_BASE64 decodes to 0 bytes — the secret is empty or truncated.")
    }
    return bytes
}

fun verifyCiKeystore(ksFile: File, storePassword: String, keyAlias: String) {
    var lastError: Exception? = null
    // PKCS12 first (keytool's default since JDK 9), JKS for older keystores.
    val store = listOf("pkcs12", "jks").firstNotNullOfOrNull { type ->
        try {
            KeyStore.getInstance(type).also { ks ->
                ksFile.inputStream().use { ks.load(it, storePassword.toCharArray()) }
            }
        } catch (e: Exception) {
            lastError = e
            null
        }
    } ?: throw GradleException(
        "Cannot read the keystore decoded from KEYSTORE_BASE64 (${ksFile.length()} bytes): ${lastError?.message}\n" +
            "The secret is either corrupted (re-encoded as text instead of raw bytes) or was created " +
            "with a different store password than KEYSTORE_PASSWORD.",
        lastError,
    )
    if (!store.containsAlias(keyAlias)) {
        throw GradleException(
            "Keystore has no alias \"$keyAlias\". Available aliases: " +
                store.aliases().toList().joinToString(", ").ifEmpty { "<none>" },
        )
    }
}

android {
    namespace = "app.glaze.flutter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    signingConfigs {
        create("ci") {
            val base64 = ciKeystoreBase64
            if (base64 != null) {
                val ksFile = rootProject.file("debug-key.keystore")
                ksFile.writeBytes(decodeCiKeystore(base64))
                storeFile = ksFile
                storePassword = ciStorePassword
                keyAlias = ciKeyAlias
                keyPassword = System.getenv("KEY_PASSWORD") ?: "android"
                verifyCiKeystore(ksFile, ciStorePassword, ciKeyAlias)
            }
        }
    }

    defaultConfig {
        applicationId = "app.glaze.flutter"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        debug {
            signingConfig = if (ciKeystoreBase64 != null) {
                signingConfigs.getByName("ci")
            } else {
                signingConfigs.getByName("debug")
            }
        }
        release {
            signingConfig = if (ciKeystoreBase64 != null) {
                signingConfigs.getByName("ci")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
