/* tools/rider/studio/raster.c -- render.py's z-buffer triangle rasterizer (built by studio.sh). stdin: int W,H,ntris; float cam[3], fwd[3], right[3], up[3], fov(deg), light[3];
   then ntris * (9 floats xyz, 4 bytes rgba). stdout: binary PPM. Two-sided Lambert + ambient. */
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
typedef struct { float v[9]; unsigned char c[4]; } Tri;
int main(void) {
  int W, H, n; float cam[3], F[3], R[3], U[3], fov, L[3];
  if (fread(&W, 4, 1, stdin) != 1) return 1; fread(&H, 4, 1, stdin); fread(&n, 4, 1, stdin);
  fread(cam, 4, 3, stdin); fread(F, 4, 3, stdin); fread(R, 4, 3, stdin); fread(U, 4, 3, stdin);
  fread(&fov, 4, 1, stdin); fread(L, 4, 3, stdin);
  Tri *t = malloc(sizeof(Tri) * (size_t)n); fread(t, sizeof(Tri), n, stdin);
  float *z = malloc(sizeof(float) * W * H); unsigned char *img = malloc(3 * W * H);
  for (int i = 0; i < W * H; i++) { z[i] = 1e30f; }
  for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {   /* sky gradient */
    float k = (float)y / H; unsigned char *p = img + 3 * (y * W + x);
    p[0] = 200 - 40 * k; p[1] = 210 - 40 * k; p[2] = 225 - 40 * k; }
  float f = 0.5f * W / tanf(fov * 0.5f * 3.14159265f / 180.f);
  for (int i = 0; i < n; i++) {
    float sx[3], sy[3], sz[3]; int ok = 1;
    for (int k = 0; k < 3; k++) {
      float d[3] = { t[i].v[3*k] - cam[0], t[i].v[3*k+1] - cam[1], t[i].v[3*k+2] - cam[2] };
      float zc = d[0]*F[0] + d[1]*F[1] + d[2]*F[2];
      float xc = d[0]*R[0] + d[1]*R[1] + d[2]*R[2];
      float yc = d[0]*U[0] + d[1]*U[1] + d[2]*U[2];
      if (zc < 1.0f) { ok = 0; break; }
      sx[k] = W * 0.5f + f * xc / zc; sy[k] = H * 0.5f - f * yc / zc; sz[k] = zc;
    }
    if (!ok) continue;
    float *v = t[i].v;
    float e1[3] = { v[3]-v[0], v[4]-v[1], v[5]-v[2] }, e2[3] = { v[6]-v[0], v[7]-v[1], v[8]-v[2] };
    float nn[3] = { e1[1]*e2[2]-e1[2]*e2[1], e1[2]*e2[0]-e1[0]*e2[2], e1[0]*e2[1]-e1[1]*e2[0] };
    float ln = sqrtf(nn[0]*nn[0]+nn[1]*nn[1]+nn[2]*nn[2]); if (ln < 1e-9f) continue;
    for (int k = 0; k < 3; k++) nn[k] /= ln;
    /* face the camera */
    float vc[3] = { cam[0]-v[0], cam[1]-v[1], cam[2]-v[2] };
    if (nn[0]*vc[0]+nn[1]*vc[1]+nn[2]*vc[2] < 0) for (int k = 0; k < 3; k++) nn[k] = -nn[k];
    float lam = nn[0]*L[0] + nn[1]*L[1] + nn[2]*L[2]; if (lam < 0) lam = 0;
    float sh = 0.38f + 0.62f * lam;
    unsigned char col[3]; for (int k = 0; k < 3; k++) { float c = t[i].c[k] * sh; col[k] = c > 255 ? 255 : (unsigned char)c; }
    int x0 = (int)floorf(fminf(sx[0], fminf(sx[1], sx[2]))), x1 = (int)ceilf(fmaxf(sx[0], fmaxf(sx[1], sx[2])));
    int y0 = (int)floorf(fminf(sy[0], fminf(sy[1], sy[2]))), y1 = (int)ceilf(fmaxf(sy[0], fmaxf(sy[1], sy[2])));
    if (x0 < 0) x0 = 0; if (y0 < 0) y0 = 0; if (x1 >= W) x1 = W - 1; if (y1 >= H) y1 = H - 1;
    float area = (sx[1]-sx[0])*(sy[2]-sy[0]) - (sx[2]-sx[0])*(sy[1]-sy[0]);
    if (fabsf(area) < 1e-8f) continue;
    for (int y = y0; y <= y1; y++) for (int x = x0; x <= x1; x++) {
      float px = x + 0.5f, py = y + 0.5f;
      float w0 = ((sx[1]-px)*(sy[2]-py) - (sx[2]-px)*(sy[1]-py)) / area;
      float w1 = ((sx[2]-px)*(sy[0]-py) - (sx[0]-px)*(sy[2]-py)) / area;
      float w2 = 1 - w0 - w1;
      if (w0 < 0 || w1 < 0 || w2 < 0) continue;
      float iz = w0 / sz[0] + w1 / sz[1] + w2 / sz[2]; float zz = 1.0f / iz;
      int o = y * W + x;
      if (zz < z[o]) { z[o] = zz; img[3*o] = col[0]; img[3*o+1] = col[1]; img[3*o+2] = col[2]; }
    }
  }
  printf("P6\n%d %d\n255\n", W, H); fwrite(img, 3, W * H, stdout);
  return 0;
}
