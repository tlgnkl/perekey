// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import CoreML
import Foundation

/// `compute-plan <mlmodelc>... [--units all|cpu-ane|cpu]`: where CoreML puts
/// the work of each model: the share of the operations' estimated cost on
/// the Neural Engine, the GPU and the CPU (`MLComputePlan`). The SoC's
/// energy counters need root, so this is the way to say "on the ANE".
@available(macOS 14.4, *)
enum ComputePlanCommand {
    static func run(_ arguments: [String]) async throws {
        var units = MLComputeUnits.all
        var paths: [String] = []
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            if argument == "--units" {
                switch rest.popFirst() {
                case "cpu-ane": units = .cpuAndNeuralEngine
                case "cpu": units = .cpuOnly
                default: units = .all
                }
            } else {
                paths.append(argument)
            }
        }
        print("model\tops\tane\tgpu\tcpu\tunknown")
        for path in paths {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            let plan = try await MLComputePlan.load(contentsOf: URL(filePath: path), configuration: configuration)
            guard case let .program(program) = plan.modelStructure else {
                print("\(URL(filePath: path).lastPathComponent)\tnot an ML program")
                continue
            }
            var cost: [String: Double] = [:]
            var count = 0
            func walk(_ block: MLModelStructure.Program.Block) {
                for operation in block.operations {
                    count += 1
                    let weight = plan.estimatedCost(of: operation)?.weight ?? 0
                    let device = switch plan.deviceUsage(for: operation)?.preferred {
                    case .neuralEngine?: "ane"
                    case .gpu?: "gpu"
                    case .cpu?: "cpu"
                    default: "unknown"
                    }
                    cost[device, default: 0] += weight
                    operation.blocks.forEach(walk)
                }
            }
            program.functions.values.forEach { walk($0.block) }
            let total = max(cost.values.reduce(0, +), 1e-12)
            let share = ["ane", "gpu", "cpu", "unknown"].map { String(format: "%.1f%%", 100 * (cost[$0] ?? 0) / total) }
            print(([URL(filePath: path).lastPathComponent, "\(count)"] + share).joined(separator: "\t"))
        }
    }
}
