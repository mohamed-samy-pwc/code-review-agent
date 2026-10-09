import { add } from './add';

describe('add', () => {
  it('intentionally fails', () => {
    // This test is written to always fail
    expect(add(2, 3)).toBe(999);
  });
});
