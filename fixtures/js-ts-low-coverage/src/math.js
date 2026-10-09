// Many uncovered branches intentionally to produce low coverage
function add(a, b) { return a + b; }
function subtract(a, b) { return a - b; }
function multiply(a, b) { return a * b; }
function divide(a, b) {
  if (b === 0) throw new Error('div by zero');
  return a / b;
}
function power(a, b) { return Math.pow(a, b); }
function factorial(n) {
  if (n < 0) throw new Error('negative');
  if (n === 0) return 1;
  return n * factorial(n - 1);
}
module.exports = { add, subtract, multiply, divide, power, factorial };
