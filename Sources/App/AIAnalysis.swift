//
//  AIAnalysis.swift
//  ID3Maps host app.
//
//  AI analysis of the charts with Apple's on-device language model (Foundation Models, iOS 26+
//  with Apple Intelligence on). The data never leaves the phone: the model runs locally and only
//  gets the per-trip aggregates (date, km, consumption, Maps' figure, temperature, speed).
//

import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
@Observable
final class ChartAnalyst {
    var text = ""
    var running = false
    var problem: String?

    static let instructions = """
    Du analyserer kørselsdata fra en elbil (VW ID.3) for ejeren. Svar altid på dansk, \
    kort og konkret: højst 6 punkter med "•", og en kort konklusion til sidst. \
    Brug kun tallene i data, og opfind ikke tal. Forbrug er i kWh pr. 100 km. \
    "Maps" er det forbrug, Apple Maps fik at vide; "afvigelse" er hvor meget mere (+) eller \
    mindre (-) bilen brugte end Maps regnede med. Forklar mønstre med temperatur, fart, \
    turlængde og tid, og sig ærligt, når der er for få ture til at konkludere.
    """

    /// Whether the on-device model can be used right now, with a reason when not.
    static var availability: (ok: Bool, reason: String) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return (true, "")
            case .unavailable(.appleIntelligenceNotEnabled):
                return (false, "Slå Apple Intelligence til under Indstillinger for at bruge AI-analysen.")
            case .unavailable(.modelNotReady):
                return (false, "Apple Intelligence er ved at blive hentet. Prøv igen om lidt.")
            case .unavailable(.deviceNotEligible):
                return (false, "Denne iPhone understøtter ikke Apple Intelligence.")
            case .unavailable:
                return (false, "Apple Intelligence er ikke tilgængelig lige nu.")
            }
        }
        #endif
        return (false, "AI-analysen kræver iOS 26 eller nyere med Apple Intelligence.")
    }

    func analyze(question: String, data: String) async {
        guard !running else { return }
        problem = nil
        text = ""
        let a = Self.availability
        guard a.ok else { problem = a.reason; return }
        running = true
        defer { running = false }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let prompt = "Spørgsmål: \(question)\n\nData (én tur pr. linje, ældste først):\n\(data)"
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let response = try await session.respond(to: prompt)
                text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                problem = "Analysen mislykkedes: \(error.localizedDescription)"
                SharedLog.shared.log("AI analysis failed: \(error)", category: "app")
            }
        }
        #endif
    }
}

/// "Analysér" button and the result, under a chart (full screen) or as its own card.
struct AnalysisPanel: View {
    let question: String
    let data: String
    var allowsOwnQuestion = false
    @State private var analyst = ChartAnalyst()
    @State private var ownQuestion = ""

    var body: some View {
        Card(title: "AI-analyse", symbol: "sparkles") {
            if allowsOwnQuestion {
                TextField("Spørg om dine ture, fx \"Hvorfor brugte jeg mere i tirsdags?\"", text: $ownQuestion, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit { run() }
            }
            HStack {
                Button { run() } label: {
                    Label(analyst.text.isEmpty ? "Analysér" : "Analysér igen", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(analyst.running)
                if analyst.running { ProgressView().padding(.leading, 6) }
            }
            if let p = analyst.problem {
                Text(p).font(.callout).foregroundStyle(.orange)
            }
            if !analyst.text.isEmpty {
                Text(analyst.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Analysen laves af Apple Intelligence direkte på telefonen. Dine data forlader ikke telefonen. AI kan tage fejl, så tjek tallene i grafen.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func run() {
        let q = ownQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await analyst.analyze(question: q.isEmpty ? question : q, data: data) }
    }
}
