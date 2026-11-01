// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/// A point of a stroke. The format also gives a direction, but drawing
/// needs the coordinates, the width, the pressure and — for the second
/// ballpoint, whose ink thins as the pen speeds up — the speed.
public struct StrokePoint: Sendable, Hashable {
    public let x: Float
    public let y: Float
    public let width: Float
    public let pressure: Float
    /// The pen's speed in version two's scale: the raw `uint16`. The tablet
    /// reads it where a reader would expect the width — the ballpoint's
    /// ink density falls from a quarter of it at 5 to 30.
    public let speed: Float

    public init(x: Float, y: Float, width: Float, pressure: Float, speed: Float = 0) {
        self.x = x
        self.y = y
        self.width = width
        self.pressure = pressure
        self.speed = speed
    }
}
