// Point d'entrée du driver.
//
// Ces deux lignes vivaient à la fin de TouchscreenDriver.swift. Swift
// n'autorise le code au niveau racine que dans un fichier nommé main.swift:
// tant qu'elles y étaient, le module ne pouvait contenir aucun autre fichier,
// et le binaire de test — qui compile les mêmes déclarations avec son propre
// main — était impossible à produire.
//
// tests/main.swift joue le même rôle pour run_tests.sh. Les deux ne sont
// jamais compilés ensemble, ce qui est exactement la contrainte voulue.

import Foundation

// Désactiver le buffering pour voir la sortie en temps réel
setbuf(stdout, nil)

main()
