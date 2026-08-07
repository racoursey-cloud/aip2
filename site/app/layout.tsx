import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'The A.I. Pickens Report',
  description:
    'A college-football publication: a weekly brief, a pregame piece, picks graded on the record, and what somebody actually watched happen.',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
