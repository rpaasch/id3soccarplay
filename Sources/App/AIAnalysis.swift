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

#if canImport(FoundationModels)
/// The structured answer the on-device model fills in (guided generation), so the app can lay
/// it out properly instead of showing raw text with stray "**".
@available(iOS 26.0, *)
@Generable
struct AIAnalysisResult {
    @Guide(description: "Én kort sætning på dansk med det vigtigste fund.")
    var headline: String
    @Guide(description: "3 til 5 fund om mønstre i data, vigtigste først.", .count(3...5))
    var points: [AIAnalysisPoint]
    @Guide(description: "Én eller to sætninger på dansk: hvad betyder det for ejeren i praksis.")
    var conclusion: String
}

@available(iOS 26.0, *)
@Generable
struct AIAnalysisPoint {
    @Guide(description: "Hvad fundet handler om.")
    var topic: AIAnalysisTopic
    @Guide(description: "Overskrift på dansk, højst 6 ord.")
    var title: String
    @Guide(description: "Forklaring på dansk, 1-2 sætninger, med de vigtigste tal.")
    var detail: String
}

@available(iOS 26.0, *)
@Generable
enum AIAnalysisTopic {
    case temperatur, fart, maps, turlaengde, tid, andet
}
#endif

/// What the panel shows: plain values, so the view needs no FoundationModels types.
struct AnalysisView: Sendable {
    struct Point: Sendable, Identifiable { let id = UUID(); let symbol: String; let tint: String; let title: String; let detail: String }
    var headline: String
    var points: [Point]
    var conclusion: String
}

@MainActor
@Observable
final class ChartAnalyst {
    var text = ""
    var result: AnalysisView?
    var running = false
    var problem: String?

    static let instructions = """
    Du analyserer kørselsdata fra en elbil (VW ID.3) for ejeren. Skriv på dansk, kort og konkret. \
    Brug kun tallene i data, og opfind ikke tal. Forbrug er i kWh pr. 100 km. "Maps" er det \
    forbrug, Apple Maps fik at vide; "afvigelse" er hvor meget mere (+) eller mindre (-) bilen \
    brugte end Maps regnede med. Beskriv mønstre (temperatur, fart, turlængde, tid) i stedet for \
    at gennemgå ture én for én; nævn en enkelt tur kun som eksempel. Sig ærligt, når der er for \
    få ture til at konkludere. Brug ikke markdown.
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

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func look(_ t: AIAnalysisTopic) -> (String, String) {
        switch t {
        case .temperatur: return ("thermometer.snowflake", "cyan")
        case .fart: return ("speedometer", "indigo")
        case .maps: return ("map", "teal")
        case .turlaengde: return ("road.lanes", "orange")
        case .tid: return ("calendar", "purple")
        case .andet: return ("lightbulb", "yellow")
        }
    }
    #endif

    func analyze(question: String, data: String) async {
        guard !running else { return }
        problem = nil
        text = ""
        result = nil
        let a = Self.availability
        guard a.ok else { problem = a.reason; return }
        running = true
        defer { running = false }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let prompt = "Spørgsmål: \(question)\n\nData (én tur pr. linje, ældste først):\n\(data)"
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let r = try await session.respond(to: prompt, generating: AIAnalysisResult.self).content
                result = AnalysisView(headline: r.headline, points: r.points.map { p in
                    let (sym, tint) = Self.look(p.topic)
                    return AnalysisView.Point(symbol: sym, tint: tint, title: p.title, detail: p.detail)
                }, conclusion: r.conclusion)
                text = r.headline
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
                .controlSize(.small)
                .disabled(analyst.running)
                if analyst.running { ProgressView().padding(.leading, 6) }
            }
            if let p = analyst.problem {
                Text(p).font(.callout).foregroundStyle(.orange)
            }
            if let r = analyst.result {
                AnalysisResultView(result: r)
            } else if !analyst.text.isEmpty {
                Text((try? AttributedString(markdown: analyst.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(analyst.text))
                    .font(.subheadline)
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

/// The analysis laid out: headline, one row per finding with an icon, and the conclusion in a box.
struct AnalysisResultView: View {
    let result: AnalysisView

    private func color(_ name: String) -> Color {
        switch name {
        case "cyan": return .cyan
        case "indigo": return .indigo
        case "teal": return .teal
        case "orange": return .orange
        case "purple": return .purple
        default: return .yellow
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(result.headline)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(result.points) { p in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: p.symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(color(p.tint))
                            .frame(width: 32, height: 32)
                            .background(color(p.tint).opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title).font(.subheadline.weight(.semibold))
                            Text(p.detail).font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.teal)
                Text(result.conclusion).font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .textSelection(.enabled)
    }
}
