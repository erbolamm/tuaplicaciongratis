# Migración del blog a `blog.tuaplicaciongratis.com`

> Guía operativa para que Javier configure el subdominio personalizado del blog de Blogger
> en Cloudflare y Blogger, y verifique que todo funciona antes de cortar el antiguo dominio.

---

## 1. Resumen ejecutivo

| Concepto           | Valor                                              |
|--------------------|----------------------------------------------------|
| Dominio origen     | URL Blogger estándar (p. ej. `*.blogspot.com`)      |
| Dominio destino    | `blog.tuaplicaciongratis.com`                      |
| Registro DNS       | `CNAME  blog  →  ghs.google.com.`                  |
| Consola Blogger    | `https://draft.blogger.com/blog/settings/2533872855233438032` |
| Plataforma DNS     | Cloudflare (gestión de `tuaplicaciongratis.com`)   |
| Tiempo propagación | 5 min – 48 h (típico < 30 min en Cloudflare)       |
| Script diagnóstico | `scripts/verificar-dns.sh`                         |

**Salida esperada del blog al terminar:** `https://blog.tuaplicaciongratis.com/` resuelve a
`ghs.google.com`, sirve HTTPS con certificado válido de Google Trust Services y muestra
el contenido del blog.

---

## 2. Parámetros exactos en Cloudflare DNS

Entrar en **Cloudflare → `tuaplicaciongratis.com` → DNS → Records** y crear (o reemplazar)
el siguiente registro. **Eliminar primero cualquier registro A o CNAME que ya exista para
`blog`** — los duplicados rompen la resolución.

| Tipo  | Nombre | Destino          | Proxy / TTL               |
|-------|--------|------------------|---------------------------|
| CNAME | blog   | `ghs.google.com.`| **DNS only** (nube gris) · Auto TTL |

> ⚠️ **Crítico:** el campo *Proxy status* debe estar en **DNS only** (icono de nube gris,
> **NO** la nube naranja). Blogger no funciona si Cloudflare intercepta el tráfico con
> el proxy HTTP — Google necesita ver la IP real del origen para emitir el certificado.
>
> Para comprobarlo visualmente: en Cloudflare, la columna *Proxy* muestra una nube.
> La nube gris = DNS only (correcto). La nube naranja = proxied (incorrecto, desactivar).

Notas sobre TTL:
- **TTL = Auto** es suficiente. Cloudflare ya optimiza esto y respeta la TTL de Google.
- El registro `ghs.google.com.` lleva **punto final** — es un FQDN, no omitirlo.

---

## 3. Configuración en Blogger

1. Abrir la consola del blog:
   ```
   https://draft.blogger.com/blog/settings/2533872855233438032
   ```
2. En la columna **Configuración → Dominio personalizado** (Publicar en un dominio
   personalizado / Custom domain), seleccionar **+ Configurar un dominio de terceros**
   si aún no está.
3. Introducir exactamente `https://blog.tuaplicaciongratis.com/` (con `https://` y la barra final).
4. Blogger puede pedir verificar propiedad. Hay dos caminos:
   - **TXT de verificación temporal**: si Blogger muestra un registro como
     `google-site-verification=...`, añadirlo como registro **TXT** en Cloudflare para
     el subdominio que indique, en modo DNS only. Esperar 5 min, pulsar *Guardar / Verificar*
     en Blogger.
   - **CNAME directo**: si Blogger ya validó el CNAME a `ghs.google.com`, este paso se
     considera válido y Blogger emite el certificado de Google Trust Services
     automáticamente (entre 5 y 30 minutos).
5. Una vez validado, en la sección **HTTPS** (Disponibilidad HTTPS) marcar **Sí** cuando
   aparezca disponible. Blogger emite automáticamente el cert Let's Encrypt / Google
   Trust Services.

---

## 4. Verificación automática (script)

Tras guardar los cambios en Cloudflare y Blogger, ejecutar desde la raíz del repo:

```bash
./scripts/verificar-dns.sh
```

El script realiza tres comprobaciones y devuelve un código de salida estable para CI:

| Código | Significado       | Acción recomendada                                                                |
|--------|-------------------|-----------------------------------------------------------------------------------|
| 0      | Todo correcto     | Nada. La migración está operativa.                                                |
| 1      | Fallo DNS         | Revisar el CNAME en Cloudflare — ¿apunta a `ghs.google.com.`? ¿Nube gris?         |
| 2      | Fallo SSL         | Esperar 5–30 min a que Google emita cert; comprobar que HTTPS está activo.        |
| 3      | Fallo HTTP        | Dominio responde pero Blogger no devuelve 2xx/3xx. Revisar consola de Blogger.    |
| 4      | Error de uso      | Falta `dig`, `curl` u `openssl`. Instalar con `brew install bind curl openssl`.   |

Para diagnóstico detallado con la versión de herramientas y el PATH:

```bash
./scripts/verificar-dns.sh -v
```

Para ver la ayuda rápida:

```bash
./scripts/verificar-dns.sh -h
```

El script detecta también el estado del proxy Cloudflare por inspección de IP resuelta
(compara contra los rangos públicos de Cloudflare) — útil para confirmar que el proxy
sigue en **DNS only** después del cambio.

---

## 5. Checklist paso a paso para Javier

- [ ] **1.** Abrir Cloudflare → DNS de `tuaplicaciongratis.com`.
- [ ] **2.** Borrar cualquier registro A o CNAME que ya exista para `blog`.
- [ ] **3.** Crear registro **CNAME** `blog` → `ghs.google.com.` con proxy **DNS only** (nube gris).
- [ ] **4.** Esperar 1–2 minutos para que Cloudflare propague el cambio interno.
- [ ] **5.** Abrir `https://draft.blogger.com/blog/settings/2533872855233438032`.
- [ ] **6.** En *Dominio personalizado* introducir `https://blog.tuaplicaciongratis.com/`.
- [ ] **7.** Si Blogger solicita verificación, añadir el TXT/CNAME temporal que indique y
        repetir tras 5 min.
- [ ] **8.** Activar HTTPS en Blogger cuando el switch esté disponible (puede tardar
        hasta 30 min desde la verificación).
- [ ] **9.** Desde terminal: `cd <repo-root> && ./scripts/verificar-dns.sh`.
- [ ] **10.** Confirmar que el código de salida es **0** y que el resumen muestra
        ✔ DNS, ✔ SSL, ✔ HTTP.

---

## 6. Troubleshooting

| Síntoma                                          | Causa probable                                              | Solución                                                                  |
|--------------------------------------------------|-------------------------------------------------------------|---------------------------------------------------------------------------|
| `No se obtuvo respuesta CNAME (NXDOMAIN)`        | Registro no creado, o dominio base no resuelve.             | Verificar que `tuaplicaciongratis.com` está activo en Cloudflare.         |
| `CNAME NO apunta a ghs.google.com.`              | Apunta a otro destino o tiene typo.                         | Corregir el destino a `ghs.google.com.` (con punto final).                |
| `No se pudo establecer conexión TLS`             | Proxy Cloudflare naranja activado, o cert aún no emitido.   | Cambiar proxy a **DNS only**; esperar 5–30 min tras verificación.         |
| HTTP 404 con CNAME correcto                       | Blogger no tiene configurado el dominio personalizado.      | Volver al paso 6 de la checklist.                                          |
| HTTP 521 (Cloudflare: Web server is down)        | Proxy naranja activado con origen caído.                    | Poner en DNS only (este blog no debe usar proxy).                         |
| Cert de otro dominio (p. ej. `*.blogspot.com`)   | Google aún re-emitiendo cert.                               | Esperar; el cert debería cambiar a `blog.tuaplicaciongratis.com` en <30 min.|
| `dig` no encontrado en macOS                     | `bind` no instalado por defecto.                            | `brew install bind` (Apple ya no incluye `dig`).                          |

---

## 7. Notas operativas

- El script `verificar-dns.sh` no modifica nada del repo ni de Cloudflare: es 100 % lectura.
  Puede ejecutarse en cualquier momento sin riesgo (incluido tras `git pull` para
  confirmar que la migración sigue viva).
- Para revertir la migración: basta con **borrar el registro CNAME `blog`** en Cloudflare.
  Blogger seguirá accesible por su URL `*.blogspot.com` original.
- Si en algún momento se quiere usar el proxy Cloudflare (nube naranja), hay que tener
  en cuenta que Google **no emitirá cert** y el blog dará errores 525/521. La
  recomendación es **dejarlo siempre en DNS only** para Blogger.
- Esta guía cubre sólo el subdominio `blog.`. Para más subdominios repetir el patrón
  con un CNAME propio apuntando a `ghs.google.com.`.
