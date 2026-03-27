// Commands/CheraxxCommands.swift
// CORRECCIÓN: CheraxxCommands existía duplicado en ContentView.swift.
// Ahora tiene su propio archivo. ContentView.swift y CheraxxApp.swift
// simplemente importan este símbolo (automático al pertenecer al mismo módulo).

import SwiftUI

/// Comandos del menú principal de la aplicación.
struct CheraxxCommands: Commands {
    var profileStore: ProfileStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nuevo perfil") {
                NotificationCenter.default.post(name: .createNewProfile, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        CommandMenu("Perfiles") {
            ForEach(profileStore.profiles.prefix(9).enumerated().map { $0 }, id: \.offset) { index, profile in
                Button(profile.name) {
                    profileStore.selectedProfile = profile
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))),
                                  modifiers: .command)
            }

            Divider()

            Button("Importar perfil…") {
                NotificationCenter.default.post(name: .importProfile, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])

            Button("Exportar perfil activo…") {
                NotificationCenter.default.post(name: .exportProfile, object: nil)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }

        CommandMenu("Mapper") {
            Button("Activar / Desactivar KeyMapper") {
                NotificationCenter.default.post(name: .toggleKeyMapper, object: nil)
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
        }
    }
}

// Nota: los Notification.Name están centralizados en Utils/AppNotifications.swift
