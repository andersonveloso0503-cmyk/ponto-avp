# APK do Ponto AVP (Android)

App simples que abre o Ponto AVP dentro dele, com câmera e GPS liberados.
O conteúdo vem do site, então **não precisa gerar o APK de novo** quando o sistema muda.
Só é preciso gerar outro APK se mudar o ícone, o nome ou o endereço do app.

Para gerar (Ubuntu): `apt install aapt apksigner zipalign android-sdk-platform-23 dalvik-exchange`, depois
aapt (R.java) → javac (bootclasspath android-23) → dalvik-exchange (dex) → aapt package + add classes.dex → zipalign → apksigner.
Assine sempre com a **mesma chave** (arquivo ponto-avp.jks, guardado fora do repositório); com outra chave o celular não atualiza por cima.
Lembre de aumentar `android:versionCode` no AndroidManifest.xml.
