// AnnotationToolbar.swift
// Coreo
//
// Floating toolbar displayed when annotation mode is active. Provides tool
// selection (pencil, text, arrow, eraser), a color picker, and a done button.
// Sits at the top of the workspace with a pill-shaped dark background.

import SwiftUI

/// The available annotation drawing tools.
enum AnnotationTool: String, CaseIterable {
    /// Freehand PencilKit drawing.
    case pencil
    /// Tap to place a text label.
    case text
    /// Tap start, drag to end to create a directional arrow.
    case arrow
    /// Tap an annotation to delete it.
    case eraser

    /// The SF Symbol name for this tool's icon.
    var iconName: String {
        switch self {
        case .pencil: "pencil.tip"
        case .text: "textformat"
        case .arrow: "arrow.up.right"
        case .eraser: "eraser"
        }
    }

    /// A human-readable label for accessibility.
    var label: String {
        switch self {
        case .pencil: "Pencil"
        case .text: "Text"
        case .arrow: "Arrow"
        case .eraser: "Eraser"
        }
    }
}

/// Floating toolbar for annotation mode with tool selection, color picker, and done button.
///
/// Layout: horizontal pill with tool icons, a color swatch, and a "Done" button.
/// The selected tool is highlighted with a coral accent underline.
struct AnnotationToolbar: View {
    /// The workspace view model for exiting annotation mode.
    let viewModel: WorkspaceViewModel

    /// The currently selected drawing tool.
    @Binding var selectedTool: AnnotationTool

    /// The hex string of the currently selected annotation color.
    @Binding var selectedColorHex: String

    /// Whether the color palette popover is showing.
    @State private var showColorPalette: Bool = false

    /// The app's coral accent color.
    private let accentCoral = Color(red: 1.0, green: 0.42, blue: 0.21)

    /// Semi-transparent dark background for the toolbar.
    private let toolbarBackground = Color(red: 0.1, green: 0.1, blue: 0.1).opacity(0.9)

    var body: some View {
        HStack(spacing: 4) {
            // Tool buttons
            ForEach(AnnotationTool.allCases, id: \.self) { tool in
                toolButton(for: tool)
            }

            divider

            // Color picker swatch
            colorPickerButton

            divider

            // Done button
            doneButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(toolbarBackground)
                .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)
        )
    }

    // MARK: - Tool Button

    /// A single tool selection button with an SF Symbol icon and coral highlight.
    ///
    /// - Parameter tool: The annotation tool this button represents.
    /// - Returns: A styled button view.
    @ViewBuilder
    private func toolButton(for tool: AnnotationTool) -> some View {
        let isSelected = selectedTool == tool

        Button {
            Haptic.tick()
            selectedTool = tool
            viewModel.enterAnnotationMode(tool: tool)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tool.iconName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(isSelected ? accentCoral : .white.opacity(0.7))
                    .frame(width: 36, height: 28)

                // Selection indicator
                RoundedRectangle(cornerRadius: 1)
                    .fill(isSelected ? accentCoral : Color.clear)
                    .frame(width: 20, height: 2)
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(tool.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Divider

    /// A thin vertical divider between toolbar sections.
    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(width: 1, height: 28)
            .padding(.horizontal, 4)
    }

    // MARK: - Color Picker

    /// A small colored circle that opens the palette popover when tapped.
    private var colorPickerButton: some View {
        Button {
            Haptic.tick()
            withAnimation(.easeInOut(duration: 0.2)) {
                showColorPalette.toggle()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color(hex: selectedColorHex))
                    .frame(width: 24, height: 24)

                Circle()
                    .strokeBorder(Color.white.opacity(0.4), lineWidth: 1.5)
                    .frame(width: 24, height: 24)
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .overlay(alignment: .bottom) {
            if showColorPalette {
                colorPaletteView
                    .offset(y: 44)
            }
        }
        .accessibilityLabel("Color picker")
    }

    /// The expanded color palette showing all available annotation colors.
    private var colorPaletteView: some View {
        HStack(spacing: 8) {
            ForEach(TimedAnnotation.palette, id: \.hex) { entry in
                Button {
                    Haptic.tick()
                    selectedColorHex = entry.hex
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showColorPalette = false
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color(hex: entry.hex))
                            .frame(width: 28, height: 28)

                        if entry.hex == selectedColorHex {
                            Circle()
                                .strokeBorder(accentCoral, lineWidth: 2.5)
                                .frame(width: 32, height: 32)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(entry.name)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(toolbarBackground)
                .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 3)
        )
        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
    }

    // MARK: - Done Button

    /// The button that exits annotation mode.
    private var doneButton: some View {
        Button {
            Haptic.light()
            viewModel.exitAnnotationMode()
        } label: {
            Text("Done")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(accentCoral)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Exit annotation mode")
    }
}
