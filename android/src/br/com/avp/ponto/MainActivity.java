package br.com.avp.ponto;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.view.View;
import android.view.Window;
import android.webkit.GeolocationPermissions;
import android.webkit.PermissionRequest;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;

import java.util.ArrayList;

public class MainActivity extends Activity {
    private static final String APP_URL = "https://andersonveloso0503-cmyk.github.io/ponto-avp/";
    private static final String HOST = "andersonveloso0503-cmyk.github.io";
    private static final int PEDIDO_PERMISSOES = 10;

    private WebView web;
    private PermissionRequest pedidoCameraPendente;
    private GeolocationPermissions.Callback pedidoGpsPendente;
    private String origemGpsPendente;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Window w = getWindow();
        w.setStatusBarColor(Color.parseColor("#0F1B2D"));

        web = new WebView(this);
        web.setBackgroundColor(Color.parseColor("#0F1B2D"));
        setContentView(web);

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setGeolocationEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setAllowFileAccess(false);
        s.setCacheMode(WebSettings.LOAD_DEFAULT);
        s.setUserAgentString(s.getUserAgentString() + " PontoAVPApp/1.0");

        web.setWebViewClient(new WebViewClient() {
            @SuppressWarnings("deprecation")
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, String url) {
                return abrirFora(Uri.parse(url));
            }
        });

        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onGeolocationPermissionsShowPrompt(String origin, GeolocationPermissions.Callback callback) {
                if (temPermissao(Manifest.permission.ACCESS_FINE_LOCATION)) {
                    callback.invoke(origin, true, false);
                } else {
                    origemGpsPendente = origin;
                    pedidoGpsPendente = callback;
                    pedirPermissoes(new String[]{Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION});
                }
            }

            @Override
            public void onPermissionRequest(final PermissionRequest request) {
                runOnUiThread(new Runnable() {
                    @Override public void run() {
                        if (!HOST.equals(request.getOrigin().getHost())) { request.deny(); return; }
                        if (temPermissao(Manifest.permission.CAMERA)) {
                            request.grant(request.getResources());
                        } else {
                            pedidoCameraPendente = request;
                            pedirPermissoes(new String[]{Manifest.permission.CAMERA});
                        }
                    }
                });
            }
        });

        // pede câmera e localização logo na abertura, para não travar na hora do ponto
        ArrayList<String> faltam = new ArrayList<String>();
        if (!temPermissao(Manifest.permission.CAMERA)) faltam.add(Manifest.permission.CAMERA);
        if (!temPermissao(Manifest.permission.ACCESS_FINE_LOCATION)) {
            faltam.add(Manifest.permission.ACCESS_FINE_LOCATION);
            faltam.add(Manifest.permission.ACCESS_COARSE_LOCATION);
        }
        if (!faltam.isEmpty()) pedirPermissoes(faltam.toArray(new String[0]));

        String url = APP_URL;
        Intent it = getIntent();
        if (it != null && it.getData() != null && HOST.equals(it.getData().getHost())) url = it.getData().toString();
        if (savedInstanceState != null) web.restoreState(savedInstanceState); else web.loadUrl(url);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (intent != null && intent.getData() != null && HOST.equals(intent.getData().getHost())) {
            web.loadUrl(intent.getData().toString());
        }
    }

    private boolean abrirFora(Uri uri) {
        if (uri == null) return false;
        String host = uri.getHost();
        String scheme = uri.getScheme();
        if (("https".equals(scheme) || "http".equals(scheme)) && host != null
                && (host.equals(HOST) || host.endsWith(".supabase.co") || host.equals("cdn.jsdelivr.net"))) {
            return false; // fica dentro do app
        }
        try {
            startActivity(new Intent(Intent.ACTION_VIEW, uri));
        } catch (Exception e) {
            Toast.makeText(this, "Não foi possível abrir o link.", Toast.LENGTH_SHORT).show();
        }
        return true;
    }

    private boolean temPermissao(String p) {
        return Build.VERSION.SDK_INT < 23 || checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED;
    }

    private void pedirPermissoes(String[] ps) {
        if (Build.VERSION.SDK_INT >= 23) requestPermissions(ps, PEDIDO_PERMISSOES);
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] res) {
        if (pedidoCameraPendente != null) {
            if (temPermissao(Manifest.permission.CAMERA)) pedidoCameraPendente.grant(pedidoCameraPendente.getResources());
            else pedidoCameraPendente.deny();
            pedidoCameraPendente = null;
        }
        if (pedidoGpsPendente != null) {
            pedidoGpsPendente.invoke(origemGpsPendente, temPermissao(Manifest.permission.ACCESS_FINE_LOCATION), false);
            pedidoGpsPendente = null;
        }
    }

    @Override
    protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out);
        web.saveState(out);
    }

    @Override
    public void onBackPressed() {
        if (web.canGoBack()) web.goBack(); else super.onBackPressed();
    }
}
