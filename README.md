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

v3.5.3 - Nouvelle gestion Mono/Multisites pour les puissances & Affichage Capteur T° en MonoPage

v3.5.4 - Choix des capteurs de température à afficher

v3.5.5 - Gestion affichage/masquage de la 2e Sonde selon les libellés

v4.0.20 - Graphiques 10mn/48h/1an

v4.0.27 - Couleur textes configurable, toggle sélection jauges

v4.0.30 - Couleurs Tarif RTE

v4.0.31 - Correction de Bug affichage & Safe Area

v..... - Debug et améliorations non publiées

v4.6.3 - Intégration Suivi Solaire pour : Izypower / Sunology / EasyPower(APsystems)

v4.7.0 - Ajout info date/heure dans graphiques

v4.7.2 - Ajout personnalisation ordre des MO pour Easypower + Correction de bugs

v4.7.3 - Production Jour/Mois/Total Izypower

v4.7.4 - Correction positionnement des affichages

v4.7.5 - Ajout du cumul production journalière sous la jauge

v4.7.6 - Report production live du suivi solaire sur Page 1 en Monopage

v4.7.7 - Correction Bug Forçage

v4.8.1 - Intégration Hoymiles S-Miles Cloud (auth multi-profils Argon2id) + transparence infobulle graphique

v4.8.2 - Transparence infobulles graphiques 1an, axe Y fixe sur le graphique 1 an

v4.8.5 - Hoymiles via OpenDTU

v4.8.6 - Énergie jour Wh affichée sur Soutiré/Injecté avec support mono/triphasé

v4.8.7 - Correction Bug affichage OpenDTU + Bloc Injecté en Triphasé

v4.8.8 - Correctifs zones sûres (haut/bas) du panneau de configuration

v4.8.9 - Compatibilité panneau de config avec Samsung S10

v4.9.0 - Correction Bug de test de connexion

--------


A compiler sur Android Studio: 

  flutter clean
  
  flutter pub get 
  
  flutter build apk --release 
  
  flutter install


