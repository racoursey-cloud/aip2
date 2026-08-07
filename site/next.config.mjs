/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // Every page renders on the server. The database is reached with a service-role key that
  // must never reach a browser bundle, so nothing here is statically exported.
  output: 'standalone',
};

export default nextConfig;
