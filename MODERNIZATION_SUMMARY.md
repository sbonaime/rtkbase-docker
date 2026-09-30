# Modernisation RTKBase Docker

## Travaux effectués
- **Fusion de la documentation** : Le fichier `Teltonika-rtkbase.md` a été fusionné dans le `README.md`.
- **Adaptation du vocabulaire** : Remplacement des références à "USB flash drive" par "répertoire d'installation du conteneur" pour être plus générique.
- **Instructions Teltonika RUTC50** : Ajout des précisions sur la nécessité d'un hub USB (pour combiner clé USB et GPS) et l'obligation d'utiliser le format ext4 (avec procédure de formatage).
- **Mise à jour de la recette** : `RTKBASE_DOCKER_RECIPE.md` a été enrichi avec :
    - L'orientation vers le déploiement sur modem Teltonika.
    - La section sur les tests fonctionnels sur macOS (Apple Silicon).

## État actuel
- Le projet est structuré pour être buildé sur Mac et déployé sur Teltonika.
- Le script `start-rtkbase-rutc50.sh` est le point d'entrée pour le déploiement sur routeur.

## À faire / Points de vigilance
- Vérifier la compatibilité des nouveaux chemins de montage si le répertoire d'installation change.
- Valider que le script de démarrage gère correctement tous les cas de figure de détection USB sur RutOS.
