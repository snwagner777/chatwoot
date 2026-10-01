import postcss from 'postcss';
import tailwindcss from 'tailwindcss';
import { colors } from '../../../../../theme/colors';

describe('operator brand CSS', () => {
  it('compiles native brand opacity utilities with the scoped color', async () => {
    const result = await postcss([
      tailwindcss({
        content: [{ raw: '', extension: 'html' }],
        theme: { colors },
        corePlugins: { preflight: false },
      }),
    ]).process('.native-editor { @apply bg-n-brand hover:bg-n-brand/90; }', {
      from: undefined,
    });

    expect(result.css).toContain('rgb(var(--inbox2-brand-color, 39 129 246)');
    expect(result.css).toContain('/ 0.9)');
  });
});
