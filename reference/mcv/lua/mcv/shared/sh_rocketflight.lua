// Game flight approximation in Source units (one unit = one inch).
// Constant gravity; optional finite, linear boost along the launch direction.
// Returns distance along that direction and its current speed, before gravity.
function MCV.RocketFlightDistance(t, speed, boostSpeed, delay, duration)
    t = math.max(t, 0)
    duration = math.max(duration or 0, 0.001)
    local burning = math.Clamp(t - (delay or 0), 0, duration)
    local coast = math.max(t - (delay or 0) - duration, 0)
    local gain = math.max((boostSpeed or speed) - speed, 0)
    return speed * t + gain * (burning * burning / (2 * duration) + coast),
        speed + gain * burning / duration
end
