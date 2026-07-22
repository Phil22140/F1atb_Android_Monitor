# F1atb Android Monitor

un petit programme Android pour Monitorer et Controller l'ESP32 du routeur Solaire F1atb

Historique versions publiées :

v1.0.0 - 

v2.0.0 - affichage de la jauge d'ouverture

v2.1.0 - affichage équivalence d'ouverture

v2.2.0 - prise en charge du forçage

v2.3.0 - prise en charge du mot de passe pour le Forçage ON/OFF

v2.4.0 - affichage des capteurs de températures si présents/configurés

v2.4.1 - correction alignement affichage capteurs 

v2.5.1 - prise en charge des Relais SSR & Multi Modules pour le forçage individuel

v2.6.2 - Prise en charge l'orientation Smartphone/Tablette avec possibilité de figer en Portrait ou Paysage & Info version RMS

v3.0.2 - Prise en charge de plusieurs EPS en multipage

v3.3.0 - Prise en charge seconde sonde si déclarée & corrections bug sauvegarde multi ESP

v3.3.1 - Masquage 2e sonde si Source=Ext ou ShellyPro

v3.4.5 - Gestion Mode Page unique/Multi ESP, Choix des jauges affichée & test connexion aux ESP dans Config

v3.4.7 - Correction de bug en cas d'absence de sélection de jauges

v3.5.3 - Nouvelle gestion Mono/Multisite pour les puissances & Affichage Capteur T° en MonoPage


--------


A compiler sur Android Studio: 

  flutter clean
  
  flutter pub get 
  
  flutter build apk --release 
  
  flutter install


