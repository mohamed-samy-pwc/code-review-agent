// Only tests add — leaves subtract, multiply, divide, power, factorial uncovered
const { add } = require('./math');
test('add', () => { expect(add(1, 2)).toBe(3); });
