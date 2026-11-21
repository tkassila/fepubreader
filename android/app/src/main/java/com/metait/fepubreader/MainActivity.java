package com.metait.fepubreader;

import android.view.WindowManager;
import androidx.annotation.NonNull;
import io.flutter.embedding.android.FlutterFragmentActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends FlutterFragmentActivity {
  private static final String SCREEN_CHANNEL = "com.metait.fepubreader/screen";
  private static final String PDF_METADATA_CHANNEL = "com.metait.fepubreader/pdf_metadata";

  @Override
  public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
    super.configureFlutterEngine(flutterEngine);
    new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), SCREEN_CHANNEL)
        .setMethodCallHandler(
            (call, result) -> {
              if ("setKeepScreenOn".equals(call.method)) {
                Boolean keepOn = call.argument("keepOn");
                if (Boolean.TRUE.equals(keepOn)) {
                  getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                } else {
                  getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                }
                result.success(null);
              } else {
                result.notImplemented();
              }
            });

    new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), PDF_METADATA_CHANNEL)
        .setMethodCallHandler(
            (call, result) -> {
              if ("extractPdfMetadata".equals(call.method)) {
                String filePath = call.argument("filePath");
                Boolean saveBack = call.argument("saveBackToPdf");
                boolean save = saveBack != null && saveBack;
                if (filePath == null || filePath.isEmpty()) {
                  result.error("INVALID_PATH", "Tiedostopolku puuttuu", null);
                  return;
                }
                new Thread(() -> {
                  try {
                    java.util.Map<String, Object> res = PdfMetadataFixer.INSTANCE.suoritaMetaErikoiskysely(
                        getApplicationContext(),
                        filePath,
                        save
                    );
                    runOnUiThread(() -> result.success(res));
                  } catch (Exception e) {
                    runOnUiThread(() -> result.error("PDFBOX_ERROR", e.getMessage(), null));
                  }
                }).start();
              } else {
                result.notImplemented();
              }
            });
  }
}
